defmodule ExVrp.Literature.GroupSummary do
  @moduledoc """
  What a literature run says about one group, computed from its JSON-lines records.

  Seeds are averaged per instance first and instances then weigh equally, as in PyVRP's
  protocol. `mean_gap_to_bks` is measured against the source's best-known costs, the same
  reference PyVRP's published gaps use; `mean_gap_to_best_known` against the lowest known
  cost, CVRPLib's newer bounds included. The standard error is the spread of per-instance
  gaps over the square root of the instance count, so a sample run carries its sampling
  noise into the comparison with PyVRP's full-set numbers.
  """

  alias ExVrp.Literature.BenchmarkGroup
  alias ExVrp.Literature.Gap

  @budget_fractions [0.1, 0.25, 0.5, 1.0]

  @type t :: %__MODULE__{
          group: BenchmarkGroup.t(),
          instances: non_neg_integer(),
          seeds: non_neg_integer(),
          infeasible_solves: non_neg_integer(),
          unsolved_instances: [String.t()],
          mean_gap_to_bks: float() | nil,
          standard_error: float() | nil,
          mean_gap_to_best_known: float() | nil,
          best_of_seeds_gap: float() | nil,
          proven_optimal: non_neg_integer(),
          optimum_reached: non_neg_integer(),
          gap_over_budget: [{float(), float() | nil}],
          worst_instances: [{String.t(), float()}],
          instance_gaps: [%{name: String.t(), num_clients: pos_integer(), gap: float()}],
          iterations_per_second: float() | nil
        }

  defstruct [
    :group,
    :instances,
    :seeds,
    :infeasible_solves,
    :unsolved_instances,
    :mean_gap_to_bks,
    :standard_error,
    :mean_gap_to_best_known,
    :best_of_seeds_gap,
    :proven_optimal,
    :optimum_reached,
    :gap_over_budget,
    :worst_instances,
    :instance_gaps,
    :iterations_per_second
  ]

  @spec from_records([map()]) :: [t()]
  def from_records(records) do
    records
    |> Enum.group_by(& &1["group"])
    |> Enum.flat_map(fn {name, group_records} -> summarise(BenchmarkGroup.id_from_name(name), group_records) end)
    |> Enum.sort_by(&group_position/1)
  end

  @doc """
  How the group's mean gap compares with a PyVRP release's published gap: within two
  standard errors is noise; otherwise better or worse by the difference.
  """
  @spec pyvrp_comparison(t(), String.t()) :: {:within_noise | :better | :worse, float()} | nil
  def pyvrp_comparison(%__MODULE__{group: %{pyvrp_published_gaps: nil}}, _version), do: nil
  def pyvrp_comparison(%__MODULE__{mean_gap_to_bks: nil}, _version), do: nil
  def pyvrp_comparison(%__MODULE__{standard_error: nil}, _version), do: nil

  def pyvrp_comparison(%__MODULE__{group: group, mean_gap_to_bks: gap, standard_error: standard_error}, version) do
    difference = gap - Map.fetch!(group.pyvrp_published_gaps, version) / 100
    {comparison_verdict(difference, 2 * standard_error), difference}
  end

  defp comparison_verdict(difference, noise) when abs(difference) <= noise, do: :within_noise
  defp comparison_verdict(difference, _noise) when difference < 0, do: :better
  defp comparison_verdict(_difference, _noise), do: :worse

  defp summarise({:error, _unknown_group}, _records), do: []

  defp summarise({:ok, group_id}, records) do
    {:ok, group} = BenchmarkGroup.fetch(group_id)

    per_instance =
      records |> Enum.group_by(& &1["instance"]) |> Enum.map(fn {name, seeds} -> instance_result(name, seeds) end)

    solved = Enum.filter(per_instance, & &1.mean_objective)

    [struct!(__MODULE__, Map.merge(counts(group, records, per_instance), gaps(records, solved)))]
  end

  defp group_position(%__MODULE__{group: %{id: id}}), do: Enum.find_index(BenchmarkGroup.all(), &(&1.id == id))

  defp counts(group, records, per_instance) do
    %{
      group: group,
      instances: length(per_instance),
      seeds: records |> Enum.map(& &1["seed"]) |> Enum.uniq() |> length(),
      infeasible_solves: Enum.count(records, &(not &1["feasible"])),
      unsolved_instances: for(result <- per_instance, is_nil(result.mean_objective), do: result.name),
      proven_optimal: Enum.count(per_instance, & &1.optimal),
      optimum_reached: Enum.count(per_instance, &(&1.optimal and &1.best_of_seeds_gap == 0.0)),
      iterations_per_second: records |> Enum.map(&(&1["iterations"] / max(&1["time_ms"], 1) * 1000)) |> median()
    }
  end

  defp gaps(records, solved) do
    gaps_to_bks = Enum.map(solved, & &1.gap_to_bks)
    by_gap = Enum.sort_by(solved, & &1.gap_to_best_known, :desc)

    %{
      mean_gap_to_bks: mean(gaps_to_bks),
      standard_error: standard_error(gaps_to_bks),
      mean_gap_to_best_known: solved |> Enum.map(& &1.gap_to_best_known) |> mean(),
      best_of_seeds_gap: solved |> Enum.map(& &1.best_of_seeds_gap) |> mean(),
      gap_over_budget: Enum.map(@budget_fractions, &{&1, mean_gap_at_fraction(records, &1)}),
      worst_instances: by_gap |> Enum.take(3) |> Enum.map(&{&1.name, &1.gap_to_best_known}),
      instance_gaps: Enum.map(solved, &%{name: &1.name, num_clients: &1.num_clients, gap: &1.gap_to_best_known})
    }
  end

  defp instance_result(
         name,
         [%{"bks" => bks, "best_known" => best_known, "optimal" => optimal, "num_clients" => num_clients} | _rest] =
           seeds
       ) do
    objectives = for %{"feasible" => true, "objective" => objective} <- seeds, do: objective
    mean_objective = mean(objectives)

    %{
      name: name,
      num_clients: num_clients,
      optimal: optimal,
      mean_objective: mean_objective,
      gap_to_bks: Gap.of(mean_objective, bks),
      gap_to_best_known: Gap.of(mean_objective, best_known),
      best_of_seeds_gap: Gap.of(Enum.min(objectives, fn -> nil end), best_known)
    }
  end

  defp mean_gap_at_fraction(records, fraction) do
    records
    |> Enum.map(&Gap.of(cost_at(&1["trace"], fraction * &1["budget_s"] * 1000), &1["best_known"]))
    |> Enum.reject(&is_nil/1)
    |> mean()
  end

  defp cost_at(trace, elapsed_ms) do
    trace
    |> Enum.take_while(fn [point_ms, _cost] -> point_ms <= elapsed_ms end)
    |> List.last()
    |> trace_cost()
  end

  defp trace_cost(nil), do: nil
  defp trace_cost([_elapsed_ms, cost]), do: cost

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp standard_error([]), do: nil
  defp standard_error([_single]), do: nil

  defp standard_error(values) do
    count = length(values)
    average = mean(values)
    variance = Enum.sum_by(values, &((&1 - average) ** 2)) / (count - 1)
    :math.sqrt(variance / count)
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end
end

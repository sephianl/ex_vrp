defmodule ExVrp.ABBenchmark.SpeedComparison do
  @moduledoc """
  Compares two `ExVrp.ABBenchmark.Speed` results and decides whether the candidate
  made the search slower.

  Instruction counts repeat within 0.05% on one machine, so unlike the objective a
  change in them needs no per-instance noise band: anything past `result_threshold/0`
  is a result. The candidate fails when the median instance runs more than 1% more
  instructions per iteration, because a real slowdown moves most instances, and a
  single instance past 2% warns. When the two refs end on different distances they
  searched differently, so their counts cover different work, and the row says so.
  """

  defmodule Row do
    @moduledoc false
    @type t :: %__MODULE__{
            id: String.t(),
            baseline_per_iteration: float(),
            candidate_per_iteration: float(),
            pct_change: float(),
            path_changed: boolean()
          }
    @enforce_keys [:id, :baseline_per_iteration, :candidate_per_iteration, :pct_change, :path_changed]
    defstruct @enforce_keys
  end

  @result_threshold 0.005
  @median_fail_threshold 0.01
  @instance_warn_threshold 0.02

  @spec result_threshold() :: float()
  def result_threshold, do: @result_threshold

  @spec analyze(map(), map()) :: %{rows: [Row.t()], missing: [String.t()]}
  def analyze(%{"instances" => baseline}, %{"instances" => candidate}) do
    ids = baseline |> Map.keys() |> Enum.sort()
    {common, missing} = Enum.split_with(ids, &Map.has_key?(candidate, &1))
    %{rows: Enum.map(common, &build_row(&1, baseline[&1], candidate[&1])), missing: missing}
  end

  @spec hard_fails(%{rows: [Row.t()], missing: [String.t()]}) :: [String.t()]
  def hard_fails(%{rows: rows, missing: missing}) do
    missing_fails(missing) ++ (rows |> Enum.map(& &1.pct_change) |> median() |> median_fail())
  end

  @spec warnings([Row.t()]) :: [String.t()]
  def warnings(rows) do
    for %Row{pct_change: pct} = row <- rows, pct > @instance_warn_threshold do
      "#{row.id}: #{fmt_pct(pct)} instructions per iteration (threshold +2%)#{path_note(row)}"
    end
  end

  @spec results([Row.t()]) :: [String.t()]
  def results(rows) do
    for %Row{pct_change: pct} = row <- rows, abs(pct) > @result_threshold do
      "#{row.id}: #{fmt_pct(pct)} instructions per iteration#{path_note(row)}"
    end
  end

  defp build_row(id, baseline, candidate) do
    %{"instructions_per_iteration" => base, "distances" => base_distances} = baseline
    %{"instructions_per_iteration" => cand, "distances" => cand_distances} = candidate

    %Row{
      id: id,
      baseline_per_iteration: base,
      candidate_per_iteration: cand,
      pct_change: (cand - base) / base,
      path_changed: base_distances != cand_distances
    }
  end

  defp missing_fails(missing) do
    for id <- missing, do: "#{id}: speed measured on baseline but not on candidate"
  end

  defp median_fail(median_pct) when is_float(median_pct) and median_pct > @median_fail_threshold,
    do: ["median instance runs #{fmt_pct(median_pct)} instructions per iteration (> +1%): the search got slower"]

  defp median_fail(_median_pct), do: []

  defp path_note(%Row{path_changed: true}), do: " (search path changed, so this also counts different work)"
  defp path_note(%Row{path_changed: false}), do: ""

  defp median([]), do: nil
  defp median(values), do: values |> Enum.sort() |> middle_of_sorted(length(values))

  defp middle_of_sorted(sorted, count) when rem(count, 2) == 1, do: Enum.at(sorted, div(count, 2))
  defp middle_of_sorted(sorted, count), do: (Enum.at(sorted, div(count, 2) - 1) + Enum.at(sorted, div(count, 2))) / 2

  defp fmt_pct(x) when x >= 0, do: "+#{Float.round(x * 100, 2)}%"
  defp fmt_pct(x), do: "#{Float.round(x * 100, 2)}%"
end

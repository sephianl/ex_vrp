defmodule ExVrp.ABBenchmark.Runner do
  @moduledoc """
  Solves the corpus on the current checkout and returns a results map matching
  the documented JSON shape.

  A solve that errors, times out, or an instance that fails to load is recorded
  as infeasible rather than omitted, so the A/B comparison never loses an instance.

  All seeds of an instance start together so that each one sees the same CPU
  contention. Local search runs on dirty CPU schedulers, so asking for more seeds
  than the machine has of those makes the surplus seeds queue; because every solve
  stops on wall-clock, the queued seeds then run on an idle machine, complete more
  iterations, and pull the mean down. `run/1` warns when that is the case.
  """

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Loader
  alias ExVrp.PenaltyManager
  alias ExVrp.Solution
  alias ExVrp.StoppingCriteria

  require Logger

  @default_seeds [1, 2, 3]
  @default_budget_cap_s 180.0
  @budget_rate_s_per_loc 0.3
  @min_budget_s 10.0

  @spec default_seeds() :: [pos_integer()]
  def default_seeds, do: @default_seeds

  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    entries = Keyword.get(opts, :entries, Corpus.entries())
    seeds = Keyword.get(opts, :seeds, @default_seeds)
    ref = Keyword.get(opts, :ref, "unknown")
    commit = Keyword.get(opts, :commit, "unknown")
    budget_override = Keyword.get(opts, :budget_s)
    cap = Keyword.get(opts, :budget_cap_s, @default_budget_cap_s)

    workers = solve_workers()
    warn_if_oversubscribed(length(seeds), workers)

    instances =
      for entry <- entries, into: %{} do
        {entry.id, run_instance(entry, seeds, budget_override, cap)}
      end

    %{
      "ref" => ref,
      "commit" => commit,
      "seeds" => seeds,
      "solve_workers" => workers,
      "instances" => instances
    }
  end

  defp solve_workers, do: :erlang.system_info(:dirty_cpu_schedulers_online)

  defp warn_if_oversubscribed(seed_count, workers) when seed_count <= workers, do: :ok

  defp warn_if_oversubscribed(seed_count, workers) do
    Logger.warning(
      "[bench] #{seed_count} seeds but only #{workers} dirty CPU schedulers. " <>
        "Surplus seeds queue and then solve on an idle machine, so they finish more " <>
        "iterations than the rest and bias the mean downwards. Use at most #{workers} seeds."
    )
  end

  defp run_instance(entry, seeds, budget_override, cap) do
    case safe_load(entry) do
      {:ok, model} ->
        n = ExVrp.Model.num_locations(model)
        budget_s = budget_override || budget_for(n, cap)
        Logger.warning("[bench] #{entry.id}: n=#{n}, budget=#{budget_s}s, seeds=#{inspect(seeds)}")
        instance_record(entry, solve_seeds(model, seeds, budget_s))

      {:error, msg} ->
        Logger.warning("[bench] #{entry.id}: load failed — #{msg}")
        instance_record(entry, failed_seeds(seeds))
    end
  end

  defp safe_load(entry) do
    {:ok, Loader.load(entry)}
  rescue
    e in [ArgumentError, RuntimeError, MatchError, KeyError, File.Error, ErlangError] ->
      {:error, Exception.message(e)}
  end

  defp solve_seeds(model, seeds, budget_s) do
    seeds
    |> Task.async_stream(
      fn seed -> {seed, solve_once(model, budget_s, seed)} end,
      max_concurrency: length(seeds),
      timeout: round(budget_s * 1000) + 60_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.map(&stream_result/1)
    |> Map.new(fn {seed, data} -> {to_string(seed), data} end)
    |> ensure_all_seeds(seeds)
  end

  defp stream_result({:ok, {seed, data}}), do: {seed, data}
  defp stream_result({:exit, _reason}), do: {:__timeout__, infeasible_record(0)}

  defp ensure_all_seeds(map, seeds) do
    present = map |> Map.keys() |> Enum.reject(&(&1 == "__timeout__"))
    missing = seeds |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in present))

    timeouts = for s <- missing, into: %{}, do: {s, infeasible_record(0)}

    map
    |> Map.delete("__timeout__")
    |> Map.merge(timeouts)
  end

  @dialyzer {:nowarn_function, solve_once: 3}
  defp solve_once(model, budget_s, seed) do
    {elapsed_us, outcome} =
      :timer.tc(fn ->
        try do
          {:ok, result} =
            ExVrp.solve(model, stop: StoppingCriteria.max_runtime(budget_s), seed: seed, num_starts: 1)

          {:ok, result}
        rescue
          e in [ArgumentError, RuntimeError, MatchError, ErlangError] ->
            {:error, Exception.message(e)}
        end
      end)

    case outcome do
      {:ok, result} ->
        best = result.best

        %{
          "objective" => feasible_objective(best),
          "distance" => best.distance,
          "feasible" => best.is_feasible,
          "num_clients" => best.num_clients,
          "time_ms" => div(elapsed_us, 1000),
          "iterations" => Map.get(result, :num_iterations, 0)
        }

      {:error, _msg} ->
        infeasible_record(div(elapsed_us, 1000))
    end
  end

  defp feasible_objective(%{is_feasible: false}), do: nil

  defp feasible_objective(solution) do
    pm = PenaltyManager.init_from(solution.problem_data)
    {:ok, cost_evaluator} = PenaltyManager.max_cost_evaluator(pm)
    Solution.cost(solution, cost_evaluator)
  end

  defp failed_seeds(seeds), do: for(s <- seeds, into: %{}, do: {to_string(s), infeasible_record(0)})

  defp infeasible_record(time_ms),
    do: %{"objective" => nil, "feasible" => false, "time_ms" => time_ms, "iterations" => 0}

  defp instance_record(entry, seed_results) do
    feasible_objs = for {_s, m} <- seed_results, m["feasible"], do: m["objective"]

    %{
      "variant" => to_string(entry.variant),
      "bks" => Corpus.bks(entry.id),
      "seeds" => seed_results,
      "mean_objective" => mean(feasible_objs),
      "feasible_count" => length(feasible_objs)
    }
  end

  defp budget_for(n, cap) do
    n
    |> Kernel.*(@budget_rate_s_per_loc)
    |> max(@min_budget_s)
    |> min(cap)
    |> Float.round(1)
  end

  defp mean([]), do: nil
  defp mean(list), do: Enum.sum(list) / length(list)
end

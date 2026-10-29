defmodule ExVrp.ABBenchmark.Solve do
  @moduledoc """
  One single-start solve of a benchmark instance under a wall-clock budget, as the
  per-seed record both benchmark harnesses store. A solve that raises is recorded as
  infeasible instead of crashing the run.

  The objective is `Solution.cost/2`: distance plus fixed and per-unit vehicle costs
  and missed prizes, and `nil` when the solution is infeasible. The A/B harness also
  solves base checkouts, so result fields an older solver lacks are left out, not failed on.
  """

  alias ExVrp.ABBenchmark.Instance
  alias ExVrp.PenaltyManager
  alias ExVrp.Solution
  alias ExVrp.StoppingCriteria

  @spec solve(Instance.t(), number(), integer(), (map() -> any()) | nil) :: map()
  def solve(%Instance{model: model, penalty_params: penalty_params}, budget_s, seed, on_progress) do
    {elapsed_us, outcome} = :timer.tc(fn -> run_solver(model, penalty_params, budget_s, seed, on_progress) end)
    seed_record(outcome, div(elapsed_us, 1000))
  end

  @spec infeasible_record(non_neg_integer()) :: map()
  def infeasible_record(time_ms),
    do: %{"objective" => nil, "feasible" => false, "time_ms" => time_ms, "iterations" => 0}

  @dialyzer {:nowarn_function, run_solver: 5}
  defp run_solver(model, penalty_params, budget_s, seed, on_progress) do
    ExVrp.solve(model,
      stop: StoppingCriteria.max_runtime(budget_s),
      seed: seed,
      num_starts: 1,
      penalty_params: penalty_params,
      on_progress: on_progress
    )
  rescue
    e in [ArgumentError, RuntimeError, MatchError, ErlangError] -> {:error, Exception.message(e)}
  end

  defp seed_record({:ok, %{best: best} = result}, time_ms) do
    record = %{
      "objective" => feasible_objective(best),
      "distance" => best.distance,
      "feasible" => best.is_feasible,
      "num_clients" => best.num_clients,
      "num_routes" => length(best.routes),
      "duration" => best.duration,
      "time_ms" => time_ms,
      "search_ms" => Map.get(result, :runtime),
      "iterations" => Map.get(result, :num_iterations, 0)
    }

    Map.merge(record, search_stats(Map.get(result, :stats)))
  end

  defp seed_record({:error, _reason}, time_ms), do: infeasible_record(time_ms)

  defp search_stats(%{improvements: improvements, restarts: restarts}),
    do: %{"improvements" => improvements, "restarts" => restarts}

  defp search_stats(_stats_from_an_older_solver), do: %{}

  defp feasible_objective(%{is_feasible: false}), do: nil

  defp feasible_objective(solution) do
    {:ok, cost_evaluator} = solution.problem_data |> PenaltyManager.init_from() |> PenaltyManager.max_cost_evaluator()
    Solution.cost(solution, cost_evaluator)
  end
end

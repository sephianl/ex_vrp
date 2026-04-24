defmodule ExVrp.IslandSolver do
  @moduledoc """
  Parallel Island-based ILS solver using BEAM processes.

  Each island runs an independent ILS with its own LocalSearch resource
  (independent RNG), PenaltyManager with variant parameters, and LAHC
  history buffer. Islands periodically exchange best solutions via
  message passing.

  This is an ExVRP-specific addition leveraging BEAM concurrency.
  Upstream PyVRP uses a Genetic Algorithm instead.
  """

  alias ExVrp.IteratedLocalSearch
  alias ExVrp.Native
  alias ExVrp.PenaltyManager

  require Logger

  @island_profiles [
    {50_000, 500, 1.25, 0.85},
    {20_000, 200, 1.5, 0.7},
    {100_000, 1000, 1.1, 0.95},
    {30_000, 300, 1.3, 0.8}
  ]

  defmodule Context do
    @moduledoc false
    defstruct [:cost_eval, :on_progress, :start_time]
  end

  @spec solve(reference(), (non_neg_integer() -> boolean()), keyword()) ::
          IteratedLocalSearch.Result.t()
  def solve(problem_data, stop_fn, solve_opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    num_islands = Keyword.get(solve_opts, :num_islands, System.schedulers_online())
    base_seed = Keyword.get(solve_opts, :seed, :rand.uniform(1_000_000))
    penalty_params = Keyword.get(solve_opts, :penalty_params, %PenaltyManager.Params{})
    on_progress = Keyword.get(solve_opts, :on_progress)
    max_runtime_ms = Keyword.get(solve_opts, :max_runtime_ms, nil)

    configs = island_configs(num_islands, penalty_params, base_seed)

    local_searches =
      Enum.map(configs, fn config ->
        Native.create_local_search(problem_data, config.seed)
      end)

    {:ok, cost_eval} =
      Native.create_cost_evaluator(load_penalties: [1.0], tw_penalty: 1.0, dist_penalty: 1.0)

    ctx = %Context{cost_eval: cost_eval, on_progress: on_progress, start_time: start_time}
    orchestrator = self()

    islands =
      configs
      |> Enum.zip(local_searches)
      |> Enum.map(fn {config, local_search} ->
        spawn_monitor(fn ->
          run_island(config, problem_data, local_search, stop_fn, orchestrator, max_runtime_ms, start_time)
        end)
      end)

    island_pids = MapSet.new(islands, fn {pid, _ref} -> pid end)
    result = orchestrator_loop(island_pids, nil, nil, ctx)

    runtime = System.monotonic_time(:millisecond) - start_time
    %{result | runtime: runtime}
  end

  @spec island_configs(non_neg_integer(), PenaltyManager.Params.t(), integer()) :: [map()]
  defp island_configs(num_islands, %PenaltyManager.Params{} = base_params, base_seed) do
    num_profiles = length(@island_profiles)

    Enum.map(0..(num_islands - 1), fn i ->
      {max_no_improvement, history_size, penalty_increase, penalty_decrease} =
        Enum.at(@island_profiles, rem(i, num_profiles))

      %{
        seed: base_seed + i * 7919,
        ils_params: %IteratedLocalSearch.Params{
          max_no_improvement: max_no_improvement,
          history_size: history_size
        },
        penalty_params: %{
          base_params
          | penalty_increase: penalty_increase,
            penalty_decrease: penalty_decrease
        }
      }
    end)
  end

  defp run_island(config, problem_data, local_search, stop_fn, orchestrator, max_runtime_ms, start_time) do
    penalty_manager = PenaltyManager.init_from(problem_data, config.penalty_params)
    {:ok, max_cost_eval} = PenaltyManager.max_cost_evaluator(penalty_manager)
    {:ok, empty_solution} = Native.create_solution_from_routes(problem_data, [])

    {:ok, initial_solution} =
      Native.local_search_search_run(
        local_search,
        empty_solution,
        max_cost_eval,
        remaining_timeout_ms(max_runtime_ms, start_time)
      )

    me = self()

    ils_opts = [
      seed: config.seed,
      on_migration: fn -> poll_migration() end,
      send_migration: fn best -> send(orchestrator, {:island_best, me, best}) end,
      migration_interval: 1000,
      migration_quarantine: 500,
      max_runtime_ms: remaining_budget_ms(max_runtime_ms, start_time)
    ]

    result =
      IteratedLocalSearch.run(
        problem_data,
        penalty_manager,
        local_search,
        initial_solution,
        stop_fn,
        config.ils_params,
        ils_opts
      )

    send(orchestrator, {:island_done, me, result})
  end

  defp poll_migration do
    receive do
      {:migration, solution} -> solution
    after
      0 -> nil
    end
  end

  defp remaining_timeout_ms(nil, _start_time), do: 0

  defp remaining_timeout_ms(max_runtime_ms, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    max(round(max_runtime_ms) - elapsed, 1)
  end

  defp remaining_budget_ms(nil, _start_time), do: nil

  defp remaining_budget_ms(max_runtime_ms, start_time) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    max(max_runtime_ms - elapsed, 0)
  end

  defp orchestrator_loop(remaining, best_result, best_cost, ctx) do
    if MapSet.size(remaining) == 0 do
      best_result
    else
      receive do
        {:island_best, pid, solution} ->
          handle_island_best(remaining, best_result, best_cost, ctx, pid, solution)

        {:island_done, pid, result} ->
          handle_island_done(remaining, best_result, best_cost, ctx, pid, result)

        {:DOWN, _ref, :process, pid, :normal} ->
          orchestrator_loop(MapSet.delete(remaining, pid), best_result, best_cost, ctx)

        {:DOWN, _ref, :process, pid, reason} ->
          Logger.warning("Island #{inspect(pid)} crashed: #{inspect(reason)}")
          orchestrator_loop(MapSet.delete(remaining, pid), best_result, best_cost, ctx)
      end
    end
  end

  defp handle_island_best(remaining, best_result, best_cost, ctx, pid, solution) do
    candidate_cost = Native.solution_cost(solution, ctx.cost_eval)

    if best_cost == nil or candidate_cost < best_cost do
      broadcast_migration(remaining, pid, solution)
      maybe_report_progress(ctx, solution, candidate_cost)
      orchestrator_loop(remaining, best_result, candidate_cost, ctx)
    else
      orchestrator_loop(remaining, best_result, best_cost, ctx)
    end
  end

  defp handle_island_done(remaining, best_result, best_cost, ctx, pid, result) do
    new_remaining = MapSet.delete(remaining, pid)
    result_cost = IteratedLocalSearch.Result.cost(result)

    cond do
      best_result == nil ->
        orchestrator_loop(new_remaining, result, result_cost, ctx)

      result_cost != :infinity and (best_cost == nil or result_cost < best_cost) ->
        orchestrator_loop(new_remaining, result, result_cost, ctx)

      true ->
        orchestrator_loop(new_remaining, best_result, best_cost, ctx)
    end
  end

  defp broadcast_migration(remaining, sender_pid, solution) do
    for pid <- remaining, pid != sender_pid, do: send(pid, {:migration, solution})
  end

  defp maybe_report_progress(%Context{on_progress: nil}, _solution, _cost), do: :ok

  defp maybe_report_progress(%Context{} = ctx, solution, cost) when is_function(ctx.on_progress, 1) do
    ctx.on_progress.(%{
      stage: :island_improvement,
      best_cost: cost,
      best_distance: Native.solution_distance(solution),
      is_feasible: Native.solution_is_feasible(solution),
      num_routes: length(Native.solution_routes(solution)),
      elapsed_ms: System.monotonic_time(:millisecond) - ctx.start_time
    })
  end

  defp maybe_report_progress(_ctx, _solution, _cost), do: :ok
end

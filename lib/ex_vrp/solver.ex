defmodule ExVrp.Solver do
  @moduledoc """
  Main solver interface for VRP problems.

  This module provides the `solve/2` function which is a direct port of PyVRP's
  `solve()` function. It sets up the solver components and runs Iterated Local
  Search with Late Acceptance Hill-Climbing.
  """

  alias ExVrp.IteratedLocalSearch
  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.PenaltyManager
  alias ExVrp.StoppingCriteria

  require Logger

  @type solve_opts :: [
          max_iterations: pos_integer(),
          max_runtime: pos_integer(),
          stop: StoppingCriteria.t(),
          seed: non_neg_integer(),
          num_starts: pos_integer() | :auto,
          penalty_params: PenaltyManager.Params.t(),
          ils_params: IteratedLocalSearch.Params.t(),
          on_progress: (map() -> any()) | nil
        ]

  @default_opts [
    max_iterations: 10_000,
    max_runtime: nil,
    stop: nil,
    seed: nil,
    num_starts: :auto,
    penalty_params: nil,
    ils_params: nil,
    on_progress: nil
  ]

  @doc """
  Solves a VRP model using Iterated Local Search.

  This is a port of PyVRP's `solve()` function. It:
  1. Creates the problem data from the model
  2. Initializes the PenaltyManager for dynamic penalty adjustment
  3. Creates an initial solution using local search on empty solution
  4. Runs Iterated Local Search until stopping criterion is met

  ## Options

  - `:max_iterations` - Maximum number of iterations (default: 10_000)
  - `:max_runtime` - Maximum runtime in seconds (default: unlimited). Matches PyVRP.
  - `:stop` - Custom StoppingCriteria (overrides max_iterations/max_runtime)
  - `:seed` - Random seed for reproducibility (default: random)
  - `:num_starts` - Number of parallel independent solver starts (default: `:auto`).
    Each start uses a different seed and runs its own ILS chain.
    The best result across all starts is returned.
    Use `:auto` to pick based on available cores (`div(schedulers_online, 2)`).
  - `:penalty_params` - PenaltyManager.Params for penalty adjustment
  - `:ils_params` - IteratedLocalSearch.Params for ILS behavior
  - `:on_progress` - Optional callback function receiving progress maps during ILS iterations (time-gated at ~1s intervals). When `num_starts > 1`, progress maps include `:seed_idx` and `:seed` fields.

  ## Returns

  - `{:ok, result}` - Successfully found a solution. Result has:
    - `result.best` - Best Solution found
    - `result.cost()` - Cost of best solution (infinity if infeasible)
    - `result.feasible?()` - Whether solution is feasible
    - `result.num_iterations` - Total iterations
    - `result.runtime` - Runtime in milliseconds
  - `{:error, reason}` - Failed to solve

  ## Example

      model = Model.new()
      |> Model.add_depot(x: 0, y: 0)
      |> Model.add_vehicle_type(num_available: 2, capacity: [100])
      |> Model.add_client(x: 10, y: 0, delivery: [20])

      {:ok, result} = Solver.solve(model, max_iterations: 1000)
      IO.puts("Best distance: \#{result.best.distance}")

      # With time limit (seconds, like PyVRP)
      {:ok, result} = Solver.solve(model, max_runtime: 60.0)

  """
  @dialyzer {:nowarn_function, solve: 1}
  @dialyzer {:nowarn_function, solve: 2}
  @spec solve(Model.t(), solve_opts()) :: {:ok, IteratedLocalSearch.Result.t()} | {:error, term()}
  def solve(%Model{} = model, opts \\ []) do
    solve_start = System.monotonic_time(:millisecond)
    opts = Keyword.merge(@default_opts, opts)

    base_seed = opts[:seed] || :rand.uniform(1_000_000)
    num_starts = resolve_num_starts(opts[:num_starts])

    with {:ok, problem_data} <- Model.to_problem_data(model) do
      problem_data_time = System.monotonic_time(:millisecond) - solve_start
      Logger.info("Problem data created in #{problem_data_time}ms")

      if num_starts == 1 do
        solve_single(problem_data, base_seed, opts, solve_start)
      else
        Logger.info("Starting #{num_starts} parallel solves")
        solve_parallel(problem_data, base_seed, num_starts, opts, solve_start)
      end
    end
  end

  defp solve_single(problem_data, seed, opts, solve_start) do
    :rand.seed(:exsplus, {seed, seed, seed})
    stop_fn = build_stop_fn(opts)

    {local_search, penalty_manager, initial_solution} =
      setup_solver(problem_data, seed, opts, solve_start)

    notify_progress(opts[:on_progress], %{
      stage: :initial_solution,
      num_routes: length(Native.solution_routes(initial_solution)),
      total_duration: Native.solution_duration(initial_solution),
      num_clients: Native.solution_num_clients(initial_solution),
      is_feasible: Native.solution_is_feasible(initial_solution),
      best_distance: Native.solution_distance(initial_solution)
    })

    total_setup_time = System.monotonic_time(:millisecond) - solve_start
    Logger.info("Total setup time before ILS: #{total_setup_time}ms")

    result = run_ils(problem_data, penalty_manager, local_search, initial_solution, stop_fn, opts, seed, solve_start)

    ils_time = System.monotonic_time(:millisecond) - solve_start - total_setup_time
    total_time = System.monotonic_time(:millisecond) - solve_start
    Logger.info("ILS completed in #{ils_time}ms (#{result.num_iterations} iterations)")
    Logger.info("Total solve time: #{total_time}ms (setup: #{total_setup_time}ms, ILS: #{ils_time}ms)")

    {:ok, result}
  end

  defp solve_parallel(problem_data, base_seed, num_starts, opts, solve_start) do
    tasks =
      for idx <- 0..(num_starts - 1) do
        seed = base_seed + idx
        task_opts = augment_progress_callback(opts, idx, seed)

        Task.async(fn ->
          solve_single(problem_data, seed, task_opts, solve_start)
        end)
      end

    timeout = task_timeout(opts)
    results = Task.await_many(tasks, timeout)

    pick_best_result(results, num_starts, solve_start)
  end

  defp pick_best_result(results, num_starts, solve_start) do
    successes =
      Enum.flat_map(results, fn
        {:ok, result} -> [result]
        {:error, _reason} -> []
      end)

    case successes do
      [] ->
        error =
          Enum.find_value(results, fn
            {:error, reason} -> reason
            {:ok, _result} -> nil
          end)

        {:error, error || :all_starts_failed}

      ok_results ->
        finalize_best(ok_results, num_starts, solve_start)
    end
  end

  defp finalize_best(results, num_starts, solve_start) do
    best =
      Enum.min_by(results, fn result ->
        case IteratedLocalSearch.Result.cost(result) do
          :infinity -> {1, 0}
          cost -> {0, cost}
        end
      end)

    total_runtime = System.monotonic_time(:millisecond) - solve_start
    total_iterations = Enum.sum(Enum.map(results, & &1.num_iterations))

    Logger.info(
      "Parallel solve complete: #{num_starts} starts, " <>
        "#{total_iterations} total iterations, best cost #{IteratedLocalSearch.Result.cost(best)}"
    )

    {:ok,
     %{
       best
       | runtime: total_runtime,
         stats: Map.merge(best.stats, %{num_starts: num_starts, total_iterations: total_iterations})
     }}
  end

  defp augment_progress_callback(opts, seed_idx, seed) do
    case opts[:on_progress] do
      callback when is_function(callback, 1) ->
        Keyword.put(opts, :on_progress, fn info ->
          callback.(Map.merge(info, %{seed_idx: seed_idx, seed: seed}))
        end)

      _other ->
        opts
    end
  end

  defp resolve_num_starts(:auto), do: max(div(System.schedulers_online(), 2), 1)
  defp resolve_num_starts(n) when is_integer(n) and n >= 1, do: n

  defp task_timeout(opts) do
    case opts[:max_runtime] do
      nil -> :infinity
      ms -> round(ms * 2) + 30_000
    end
  end

  defp setup_solver(problem_data, seed, opts, solve_start) do
    penalty_params = opts[:penalty_params] || %PenaltyManager.Params{}
    penalty_manager = PenaltyManager.init_from(problem_data, penalty_params)

    local_search_start = System.monotonic_time(:millisecond)
    local_search = Native.create_local_search(problem_data, seed)
    local_search_time = System.monotonic_time(:millisecond) - local_search_start
    Logger.info("LocalSearch created (neighbours computed) in #{local_search_time}ms")

    initial_solution_start = System.monotonic_time(:millisecond)
    {:ok, max_cost_eval} = PenaltyManager.max_cost_evaluator(penalty_manager)
    {:ok, empty_solution} = Native.create_solution_from_routes(problem_data, [])

    max_runtime_ms = resolve_max_runtime_ms(opts)

    init_timeout_ms =
      if max_runtime_ms do
        elapsed = System.monotonic_time(:millisecond) - solve_start
        max(round(max_runtime_ms) - elapsed, 1)
      else
        0
      end

    {:ok, initial_solution} =
      Native.local_search_search_run(local_search, empty_solution, max_cost_eval, init_timeout_ms)

    initial_solution_time = System.monotonic_time(:millisecond) - initial_solution_start
    Logger.info("Initial solution generated in #{initial_solution_time}ms")

    {local_search, penalty_manager, initial_solution}
  end

  defp run_ils(problem_data, penalty_manager, local_search, initial_solution, stop_fn, opts, seed, solve_start) do
    ils_params = opts[:ils_params] || %IteratedLocalSearch.Params{}

    Logger.info("Starting ILS iterations")

    ils_opts = [seed: seed, on_progress: opts[:on_progress]]

    max_runtime_ms = resolve_max_runtime_ms(opts)

    ils_opts =
      if max_runtime_ms do
        setup_elapsed = System.monotonic_time(:millisecond) - solve_start
        remaining_ms = max(max_runtime_ms - setup_elapsed, 0)
        Keyword.put(ils_opts, :max_runtime_ms, remaining_ms)
      else
        ils_opts
      end

    IteratedLocalSearch.run(
      problem_data,
      penalty_manager,
      local_search,
      initial_solution,
      stop_fn,
      ils_params,
      ils_opts
    )
  end

  defp notify_progress(nil, _info), do: :ok
  defp notify_progress(callback, info) when is_function(callback, 1), do: callback.(info)
  defp notify_progress(_callback, _info), do: :ok

  # Extract max_runtime_ms from opts, checking both :max_runtime and :stop criteria.
  # This ensures the NIF gets per-iteration timeouts even when using stop: criteria.
  defp resolve_max_runtime_ms(opts) do
    cond do
      opts[:max_runtime] -> opts[:max_runtime]
      opts[:stop] -> extract_max_runtime_ms(opts[:stop])
      true -> nil
    end
  end

  defp extract_max_runtime_ms(%StoppingCriteria{type: :max_runtime, state: state}), do: state.max_ms

  defp extract_max_runtime_ms(%StoppingCriteria{type: type, state: %{criteria: criteria}})
       when type in [:multiple_criteria, :any, :all] do
    Enum.find_value(criteria, &extract_max_runtime_ms/1)
  end

  defp extract_max_runtime_ms(_criteria), do: nil

  # Build stop function from options
  defp build_stop_fn(opts) do
    criteria =
      cond do
        opts[:stop] != nil ->
          opts[:stop]

        opts[:max_runtime] != nil ->
          # max_runtime is in milliseconds, convert to seconds for StoppingCriteria
          StoppingCriteria.any([
            StoppingCriteria.max_iterations(opts[:max_iterations]),
            StoppingCriteria.max_runtime(opts[:max_runtime] / 1000.0)
          ])

        true ->
          StoppingCriteria.max_iterations(opts[:max_iterations])
      end

    StoppingCriteria.to_stop_fn(criteria)
  end
end

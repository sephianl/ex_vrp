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
          penalty_params: PenaltyManager.Params.t(),
          ils_params: IteratedLocalSearch.Params.t()
        ]

  @default_opts [
    max_iterations: 10_000,
    max_runtime: nil,
    stop: nil,
    seed: nil,
    penalty_params: nil,
    ils_params: nil
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
  - `:penalty_params` - PenaltyManager.Params for penalty adjustment
  - `:ils_params` - IteratedLocalSearch.Params for ILS behavior

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

    seed = opts[:seed] || :rand.uniform(1_000_000)
    :rand.seed(:exsplus, {seed, seed, seed})

    with {:ok, problem_data} <- Model.to_problem_data(model) do
      problem_data_time = System.monotonic_time(:millisecond) - solve_start
      Logger.info("Problem data created in #{problem_data_time}ms")

      # Initialize penalty manager
      penalty_params = opts[:penalty_params] || %PenaltyManager.Params{}
      penalty_manager = PenaltyManager.init_from(problem_data, penalty_params)

      # Create persistent LocalSearch resource (computes neighbours once)
      # This matches PyVRP's behavior where LocalSearch is created once in solve()
      # and reused for all iterations. The seed initializes the RNG stored in
      # the resource, which advances across calls.
      local_search_start = System.monotonic_time(:millisecond)
      local_search = Native.create_local_search(problem_data, seed)
      local_search_time = System.monotonic_time(:millisecond) - local_search_start
      Logger.info("LocalSearch created (neighbours computed) in #{local_search_time}ms")

      # Create initial solution using greedy insertion with local search
      # This matches PyVRP's: init = ls.search(Solution(data, []), pm.max_cost_evaluator())
      Logger.info("Creating initial solution...")
      initial_solution_start = System.monotonic_time(:millisecond)
      {:ok, empty_solution} = Native.create_solution_from_routes(problem_data, [])
      {:ok, cost_evaluator} = PenaltyManager.max_cost_evaluator(penalty_manager)
      {:ok, initial_solution} = Native.local_search_search_run(local_search, empty_solution, cost_evaluator)
      initial_solution_time = System.monotonic_time(:millisecond) - initial_solution_start
      Logger.info("Initial solution generated in #{initial_solution_time}ms")

      total_setup_time = System.monotonic_time(:millisecond) - solve_start
      Logger.info("Total setup time before ILS: #{total_setup_time}ms")

      run_ils(problem_data, penalty_manager, local_search, initial_solution, opts, solve_start, total_setup_time, seed)
    end
  end

  defp run_ils(problem_data, penalty_manager, local_search, initial_solution, opts, solve_start, total_setup_time, seed) do
    # Build stopping criterion
    stop_fn = build_stop_fn(opts)

    # Run ILS
    ils_params = opts[:ils_params] || %IteratedLocalSearch.Params{}

    Logger.info("Starting ILS iterations")
    ils_start = System.monotonic_time(:millisecond)

    result =
      IteratedLocalSearch.run(
        problem_data,
        penalty_manager,
        local_search,
        initial_solution,
        stop_fn,
        ils_params,
        seed: seed
      )

    ils_time = System.monotonic_time(:millisecond) - ils_start
    total_time = System.monotonic_time(:millisecond) - solve_start
    Logger.info("ILS completed in #{ils_time}ms (#{result.num_iterations} iterations)")
    Logger.info("Total solve time: #{total_time}ms (setup: #{total_setup_time}ms, ILS: #{ils_time}ms)")

    {:ok, result}
  end

  # Build stop function from options
  defp build_stop_fn(opts) do
    criteria =
      cond do
        opts[:stop] != nil ->
          opts[:stop]

        opts[:max_runtime] != nil ->
          StoppingCriteria.any([
            StoppingCriteria.max_iterations(opts[:max_iterations]),
            StoppingCriteria.max_runtime(opts[:max_runtime])
          ])

        true ->
          StoppingCriteria.max_iterations(opts[:max_iterations])
      end

    StoppingCriteria.to_stop_fn(criteria)
  end
end

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
  @spec solve(Model.t(), solve_opts()) :: {:ok, IteratedLocalSearch.Result.t()} | {:error, term()}
  def solve(%Model{} = model, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)

    seed = opts[:seed] || :rand.uniform(1_000_000)
    :rand.seed(:exsplus, {seed, seed, seed})

    with {:ok, problem_data} <- Model.to_problem_data(model) do
      # Initialize penalty manager
      penalty_params = opts[:penalty_params] || %PenaltyManager.Params{}
      penalty_manager = PenaltyManager.init_from(problem_data, penalty_params)

      # Create persistent LocalSearch resource (computes neighbours once)
      # This matches PyVRP's behavior where LocalSearch is created once in solve()
      # and reused for all iterations. The seed initializes the RNG stored in
      # the resource, which advances across calls.
      local_search = Native.create_local_search(problem_data, seed)

      # Create initial solution from empty (matches PyVRP behavior)
      # PyVRP: init = ls.search(Solution(data, []), pm.max_cost_evaluator())
      {:ok, max_cost_eval} = PenaltyManager.max_cost_evaluator(penalty_manager)
      {:ok, empty_solution} = Native.create_solution_from_routes(problem_data, [])
      {:ok, initial_solution} = Native.local_search_search_run(local_search, empty_solution, max_cost_eval)

      # Build stopping criterion
      stop_fn = build_stop_fn(opts)

      # Run ILS
      ils_params = opts[:ils_params] || %IteratedLocalSearch.Params{}

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

      {:ok, result}
    end
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

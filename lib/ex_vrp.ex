defmodule ExVrp do
  @moduledoc """
  Elixir bindings for [PyVRP](https://github.com/PyVRP/PyVRP), a state-of-the-art
  Vehicle Routing Problem (VRP) solver.

  ExVrp uses the same C++ core as PyVRP via NIFs, providing high-performance solving
  for a wide range of VRP variants.

  ## Supported Problem Types

  - Capacitated VRP (CVRP)
  - VRP with Time Windows (VRPTW)
  - VRP with Pickups and Deliveries
  - Multi-depot VRP
  - Heterogeneous fleet VRP
  - Prize-collecting (optional clients)
  - Multi-trip / reload routes
  - Same-vehicle grouping constraints

  ## Quick Start

  Build a model, solve it, inspect the result:

      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot(x: 0, y: 0)
        |> ExVrp.Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> ExVrp.Model.add_client(x: 10, y: 10, delivery: [20])
        |> ExVrp.Model.add_client(x: 20, y: 0, delivery: [30])
        |> ExVrp.Model.add_client(x: 0, y: 20, delivery: [25])

      {:ok, result} = ExVrp.solve(model, max_iterations: 1000, seed: 42)

      result.best.routes    #=> [[1, 2], [3]]
      result.best.distance  #=> 8944
      result.best.is_feasible #=> true

  ## Solver Options

  The solver accepts these options:

  - `:max_iterations` - Maximum ILS iterations (default: `10_000`)
  - `:max_runtime` - Maximum runtime in milliseconds (default: unlimited)
  - `:seed` - Random seed for reproducibility (default: random)
  - `:num_starts` - Parallel independent solver starts (default: `:auto`).
    `:auto` uses `div(System.schedulers_online(), 2)` cores.
  - `:stop` - Custom `ExVrp.StoppingCriteria` (overrides max_iterations/max_runtime)
  - `:penalty_params` - `ExVrp.PenaltyManager.Params` for penalty tuning
  - `:ils_params` - `ExVrp.IteratedLocalSearch.Params` for ILS behavior
  - `:on_progress` - Callback function receiving progress maps

  ## Parallel Multi-Start

  By default, ExVrp runs multiple independent solver instances in parallel
  (one per two CPU cores) and returns the best result. Each start uses a
  different seed. Override with `num_starts: 1` for single-threaded solving:

      {:ok, result} = ExVrp.solve(model, num_starts: 1, seed: 42)

  ## Time Windows

      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 28_800)
        |> ExVrp.Model.add_vehicle_type(
          num_available: 3,
          capacity: [100],
          tw_early: 0,
          tw_late: 28_800
        )
        |> ExVrp.Model.add_client(
          x: 10, y: 10,
          delivery: [20],
          service_duration: 300,
          tw_early: 3600,
          tw_late: 7200
        )

      {:ok, result} = ExVrp.solve(model)

  ## Custom Stopping Criteria

      alias ExVrp.StoppingCriteria

      # Stop after 60 seconds OR 5000 iterations, whichever comes first
      stop = StoppingCriteria.any([
        StoppingCriteria.max_runtime(60.0),
        StoppingCriteria.max_iterations(5000)
      ])

      {:ok, result} = ExVrp.solve(model, stop: stop)

      # Stop when no improvement for 1000 iterations
      stop = StoppingCriteria.no_improvement(1000)
      {:ok, result} = ExVrp.solve(model, stop: stop)

  ## Inspecting Routes

      alias ExVrp.Solution

      {:ok, result} = ExVrp.solve(model)
      routes = Solution.routes(result.best)

      for route <- routes do
        IO.puts("Vehicle type: \#{route.vehicle_type}")
        IO.puts("Visits: \#{inspect(route.visits)}")
        IO.puts("Distance: \#{ExVrp.Route.distance(route)}")
      end

  ## Multi-Trip (Reload) Routes

  Vehicles can return to a reload depot mid-route to replenish capacity:

      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot(x: 0, y: 0)
        |> ExVrp.Model.add_vehicle_type(
          num_available: 1,
          capacity: [50],
          reload_depots: [0],
          max_reloads: 3
        )
        |> ExVrp.Model.add_client(x: 10, y: 0, delivery: [30])
        |> ExVrp.Model.add_client(x: 20, y: 0, delivery: [30])

  ## Prize-Collecting (Optional Clients)

  Clients can be marked as optional with a prize. The solver decides which
  clients to visit to maximise profit:

      model
      |> ExVrp.Model.add_client(
        x: 50, y: 50,
        delivery: [10],
        required: false,
        prize: 5000
      )

  ## Architecture

  - `ExVrp.Model` - Problem builder (depots, clients, vehicles, constraints)
  - `ExVrp.Solver` - Solver configuration and execution
  - `ExVrp.Solution` - Solution queries (routes, costs, feasibility, schedules)
  - `ExVrp.Route` - Per-route queries (distance, duration, load, timing)
  - `ExVrp.StoppingCriteria` - Stopping conditions (iterations, runtime, improvement)
  - `ExVrp.PenaltyManager` - Dynamic penalty adjustment
  - `ExVrp.Native` - Low-level C++ NIF bindings (via Fine)
  """

  alias ExVrp.Model
  alias ExVrp.Solution
  alias ExVrp.Solver

  @doc """
  Solve a VRP model.

  Returns `{:ok, result}` on success, `{:error, reason}` on failure.
  The result contains `result.best` (the best `ExVrp.Solution`) and metadata
  like `result.num_iterations` and `result.runtime`.

  See the module documentation for available options.

  ## Examples

      {:ok, result} = ExVrp.solve(model)
      result.best.routes
      result.best.distance

      {:ok, result} = ExVrp.solve(model, max_iterations: 5000, seed: 42)

      {:ok, result} = ExVrp.solve(model, max_runtime: 30_000)

  """
  @dialyzer {:nowarn_function, solve: 1}
  @dialyzer {:nowarn_function, solve: 2}
  @spec solve(Model.t(), keyword()) :: {:ok, Solution.t()} | {:error, term()}
  def solve(%Model{} = model, opts \\ []) do
    Solver.solve(model, opts)
  end

  @doc """
  Solve a VRP model, raising on error.

  See `solve/2` for options.

  ## Examples

      result = ExVrp.solve!(model, max_iterations: 1000)
      result.best.distance

  """
  @dialyzer {:nowarn_function, solve!: 1}
  @dialyzer {:nowarn_function, solve!: 2}
  @spec solve!(Model.t(), keyword()) :: Solution.t()
  def solve!(%Model{} = model, opts \\ []) do
    case solve(model, opts) do
      {:ok, solution} -> solution
      {:error, reason} -> raise ExVrp.SolveError, reason: reason
    end
  end
end

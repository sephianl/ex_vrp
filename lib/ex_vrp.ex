defmodule ExVrp do
  @moduledoc """
  ExVrp - Elixir bindings for PyVRP, a state-of-the-art vehicle routing problem solver.

  ## Overview

  ExVrp provides a native Elixir interface to the PyVRP solver, which implements
  a hybrid genetic algorithm for solving various Vehicle Routing Problem (VRP) variants:

  - Capacitated VRP (CVRP)
  - VRP with Time Windows (VRPTW)
  - VRP with Pickups and Deliveries (VRPPD)
  - Multi-depot VRP
  - Heterogeneous fleet VRP

  ## Quick Example

      # Define a simple problem
      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot(x: 0, y: 0)
        |> ExVrp.Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> ExVrp.Model.add_client(x: 1, y: 1, delivery: [10])
        |> ExVrp.Model.add_client(x: 2, y: 2, delivery: [20])

      # Solve
      {:ok, solution} = ExVrp.solve(model)

  ## Architecture

  The library is structured in layers:

  - `ExVrp.Native` - Low-level NIF bindings to C++ core
  - `ExVrp.Client`, `ExVrp.Depot`, etc. - Data structures
  - `ExVrp.Model` - High-level problem builder
  - `ExVrp.Solver` - Solver configuration and execution

  """

  alias ExVrp.Model
  alias ExVrp.Solution
  alias ExVrp.Solver

  @doc """
  Solve a VRP model with default parameters.

  Returns `{:ok, solution}` on success, `{:error, reason}` on failure.

  ## Options

  - `:max_iterations` - Maximum number of iterations (default: 10_000)
  - `:max_runtime` - Maximum runtime in seconds (default: none)
  - `:seed` - Random seed for reproducibility (default: random)

  ## Example

      {:ok, solution} = ExVrp.solve(model, max_iterations: 5000)

  """
  @spec solve(Model.t(), keyword()) :: {:ok, Solution.t()} | {:error, term()}
  def solve(%Model{} = model, opts \\ []) do
    Solver.solve(model, opts)
  end

  @doc """
  Solve a VRP model, raising on error.

  See `solve/2` for options.
  """
  @spec solve!(Model.t(), keyword()) :: Solution.t()
  def solve!(%Model{} = model, opts \\ []) do
    case solve(model, opts) do
      {:ok, solution} -> solution
      {:error, reason} -> raise ExVrp.SolveError, reason
    end
  end
end

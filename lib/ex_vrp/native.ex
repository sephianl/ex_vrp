defmodule ExVrp.Native do
  @moduledoc """
  Low-level NIF bindings to PyVRP C++ core.

  This module provides direct bindings to the C++ implementation.
  Users should prefer the high-level API in `ExVrp` and `ExVrp.Model`.

  ## Implementation Status

  NIFs are implemented incrementally. Unimplemented functions raise
  `ExVrp.NotImplementedError` until the C++ bindings are complete.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    path = :filename.join(:code.priv_dir(:ex_vrp), ~c"ex_vrp_nif")

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, {:reload, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # ProblemData
  # ---------------------------------------------------------------------------

  @doc """
  Creates a ProblemData resource from a Model.
  """
  @spec create_problem_data(ExVrp.Model.t()) :: {:ok, reference()} | {:error, term()}
  def create_problem_data(_model), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Solver
  # ---------------------------------------------------------------------------

  @doc """
  Runs the solver on ProblemData.
  """
  @spec solve(reference(), keyword()) :: {:ok, reference()} | {:error, term()}
  def solve(_problem_data, _opts), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Solution - Implemented NIFs
  # ---------------------------------------------------------------------------

  @spec solution_distance(reference()) :: non_neg_integer()
  def solution_distance(_solution), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_duration(reference()) :: non_neg_integer()
  def solution_duration(_solution), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_routes(reference()) :: [[non_neg_integer()]]
  def solution_routes(_solution_ref), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_is_feasible(reference()) :: boolean()
  def solution_is_feasible(_solution_ref), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_is_complete(reference()) :: boolean()
  def solution_is_complete(_solution_ref), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_num_routes(reference()) :: non_neg_integer()
  def solution_num_routes(_solution_ref), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Solution - Not Yet Implemented
  # ---------------------------------------------------------------------------

  @spec solution_num_clients(reference()) :: non_neg_integer()
  def solution_num_clients(_solution_ref), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_unassigned(reference()) :: [non_neg_integer()]
  def solution_unassigned(_solution) do
    raise ExVrp.NotImplementedError, "solution_unassigned/1"
  end

  # ---------------------------------------------------------------------------
  # CostEvaluator
  # ---------------------------------------------------------------------------

  @doc """
  Creates a CostEvaluator with penalty parameters.

  ## Options

  - `:load_penalties` - List of penalties for each load dimension (required)
  - `:tw_penalty` - Time window violation penalty (required)
  - `:dist_penalty` - Distance constraint violation penalty (required)
  """
  @spec create_cost_evaluator(keyword()) :: {:ok, reference()} | {:error, term()}
  def create_cost_evaluator(opts) when is_list(opts) do
    create_cost_evaluator_nif(Map.new(opts))
  end

  def create_cost_evaluator(opts) when is_map(opts) do
    create_cost_evaluator_nif(opts)
  end

  defp create_cost_evaluator_nif(_opts), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Computes the penalised cost of a solution (feasible or infeasible).
  """
  @spec solution_penalised_cost(reference(), reference()) :: non_neg_integer()
  def solution_penalised_cost(_solution, _cost_evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Computes the cost of a feasible solution. Returns max integer for infeasible.
  """
  @spec solution_cost(reference(), reference()) :: non_neg_integer() | :infinity
  def solution_cost(_solution, _cost_evaluator), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Random Solution
  # ---------------------------------------------------------------------------

  @doc """
  Creates a random solution for the given problem data.
  """
  @spec create_random_solution(reference(), keyword()) :: {:ok, reference()} | {:error, term()}
  def create_random_solution(problem_data, opts) when is_list(opts) do
    create_random_solution_nif(problem_data, Map.new(opts))
  end

  def create_random_solution(problem_data, opts) when is_map(opts) do
    create_random_solution_nif(problem_data, opts)
  end

  defp create_random_solution_nif(_problem_data, _opts), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the number of load dimensions from ProblemData.
  """
  @spec problem_data_num_load_dims(reference()) :: non_neg_integer()
  def problem_data_num_load_dims(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # LocalSearch
  # ---------------------------------------------------------------------------

  @doc """
  Performs local search on a solution.

  ## Options

  - `:exhaustive` - Whether to run exhaustive search (default: false)
  """
  @spec local_search(reference(), reference(), reference(), keyword()) ::
          {:ok, reference()} | {:error, term()}
  def local_search(solution, problem_data, cost_evaluator, opts \\ [])

  def local_search(solution, problem_data, cost_evaluator, opts) when is_list(opts) do
    local_search_nif(solution, problem_data, cost_evaluator, Map.new(opts))
  end

  def local_search(solution, problem_data, cost_evaluator, opts) when is_map(opts) do
    local_search_nif(solution, problem_data, cost_evaluator, opts)
  end

  defp local_search_nif(_solution, _problem_data, _cost_evaluator, _opts), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Route - Not Yet Implemented
  # ---------------------------------------------------------------------------

  @spec route_distance(ExVrp.Route.t()) :: non_neg_integer()
  def route_distance(_route) do
    raise ExVrp.NotImplementedError, "route_distance/1"
  end

  @spec route_duration(ExVrp.Route.t()) :: non_neg_integer()
  def route_duration(_route) do
    raise ExVrp.NotImplementedError, "route_duration/1"
  end

  @spec route_delivery(ExVrp.Route.t()) :: [non_neg_integer()]
  def route_delivery(_route) do
    raise ExVrp.NotImplementedError, "route_delivery/1"
  end

  @spec route_pickup(ExVrp.Route.t()) :: [non_neg_integer()]
  def route_pickup(_route) do
    raise ExVrp.NotImplementedError, "route_pickup/1"
  end

  @spec route_is_feasible(ExVrp.Route.t()) :: boolean()
  def route_is_feasible(_route) do
    raise ExVrp.NotImplementedError, "route_is_feasible/1"
  end
end

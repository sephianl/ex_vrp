defmodule ExVrp.Solution do
  @moduledoc """
  Represents a solution to a VRP.

  A solution consists of routes (one per vehicle used) and provides
  methods to compute costs, distances, and validate feasibility.
  """

  @type t :: %__MODULE__{
          routes: [[non_neg_integer()]],
          solution_ref: reference() | nil,
          problem_data: reference() | nil,
          distance: non_neg_integer(),
          duration: non_neg_integer(),
          num_clients: non_neg_integer(),
          is_feasible: boolean(),
          is_complete: boolean(),
          stats: map() | nil
        }

  defstruct routes: [],
            solution_ref: nil,
            problem_data: nil,
            distance: 0,
            duration: 0,
            num_clients: 0,
            is_feasible: true,
            is_complete: true,
            stats: nil

  @doc """
  Returns the total distance of the solution.
  """
  @spec distance(t()) :: non_neg_integer()
  def distance(%__MODULE__{distance: distance}), do: distance

  @doc """
  Returns the total duration of the solution.
  """
  @spec duration(t()) :: non_neg_integer()
  def duration(%__MODULE__{duration: duration}), do: duration

  @doc """
  Returns the total cost of the solution given a cost evaluator.
  """
  @spec cost(t(), reference()) :: non_neg_integer() | :infinity
  def cost(%__MODULE__{solution_ref: solution_ref}, cost_evaluator) do
    ExVrp.Native.solution_cost(solution_ref, cost_evaluator)
  end

  @doc """
  Returns the penalised cost of the solution given a cost evaluator.
  """
  @spec penalised_cost(t(), reference()) :: non_neg_integer()
  def penalised_cost(%__MODULE__{solution_ref: solution_ref}, cost_evaluator) do
    ExVrp.Native.solution_penalised_cost(solution_ref, cost_evaluator)
  end

  @doc """
  Returns the number of routes in the solution.
  """
  @spec num_routes(t()) :: non_neg_integer()
  def num_routes(%__MODULE__{routes: routes}) do
    length(routes)
  end

  @doc """
  Checks if the solution is feasible (satisfies all constraints).
  """
  @spec feasible?(t()) :: boolean()
  def feasible?(%__MODULE__{is_feasible: feasible}), do: feasible

  @doc """
  Checks if the solution is complete (visits all required clients).
  """
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{is_complete: complete}), do: complete

  @doc """
  Returns a list of unassigned client indices.
  """
  @spec unassigned(t()) :: [non_neg_integer()]
  def unassigned(%__MODULE__{} = solution) do
    ExVrp.Native.solution_unassigned(solution)
  end
end

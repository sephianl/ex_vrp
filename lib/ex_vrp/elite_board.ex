defmodule ExVrp.EliteBoard do
  @moduledoc """
  The best solution each start of one parallel solve has found so far, shared between the starts
  so a start that has fallen far behind can continue from the leader instead of spending the rest
  of its budget in a poor basin.

  Starts publish on every new best. At each checkpoint, a fraction of the runtime budget, a start
  whose best is more than `behind` (a fraction of the leader's cost) worse than the leader's, or
  that has nothing feasible yet, takes the leader's solution as its current solution. It keeps its
  own seed, penalties and best, so the starts that move still search differently, and starts close
  to the leader never move.

  Costs are `Native.solution_cost/2`, the objective without penalties for a feasible solution and
  `:infinity` otherwise, so starts with different penalty states compare on the same scale.
  """

  defstruct [:table, :start_index, :checkpoints_ms, :behind]

  @type t :: %__MODULE__{
          table: :ets.tid(),
          start_index: non_neg_integer(),
          checkpoints_ms: [non_neg_integer()],
          behind: float()
        }

  @doc "A board for one parallel solve, owned by the calling process."
  @spec new_table() :: :ets.tid()
  def new_table, do: :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])

  @doc "One start's view of the board, with its checkpoints as milliseconds into its search."
  @spec for_start(:ets.tid(), non_neg_integer(), [float()], float(), pos_integer()) :: t()
  def for_start(table, start_index, fractions, behind, max_runtime_ms) do
    %__MODULE__{
      table: table,
      start_index: start_index,
      checkpoints_ms: fractions |> Enum.map(&round(&1 * max_runtime_ms)) |> Enum.sort(),
      behind: behind
    }
  end

  @doc "Records a start's best."
  @spec publish(t(), non_neg_integer() | :infinity, reference()) :: true
  def publish(%__MODULE__{table: table, start_index: start_index}, cost, solution),
    do: :ets.insert(table, {start_index, cost, solution})

  @doc """
  The leader's solution when `own_cost` is far enough behind it to move, otherwise `nil`. A start
  is never told to follow itself, and an infeasible leader is never followed.
  """
  @spec leader_to_follow(t(), non_neg_integer() | :infinity) :: reference() | nil
  def leader_to_follow(%__MODULE__{} = board, own_cost) do
    board.table
    |> :ets.tab2list()
    |> Enum.reject(fn {_index, cost, _solution} -> cost == :infinity end)
    |> Enum.min_by(fn {_index, cost, _solution} -> cost end, fn -> nil end)
    |> follow(board, own_cost)
  end

  defp follow(nil, _board, _own_cost), do: nil
  defp follow({start_index, _cost, _solution}, %{start_index: start_index}, _own_cost), do: nil
  defp follow({_index, _cost, solution}, _board, :infinity), do: solution

  defp follow({_index, leader_cost, solution}, %{behind: behind}, own_cost),
    do: if(own_cost > leader_cost * (1 + behind), do: solution)
end

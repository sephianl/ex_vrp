defmodule ExVrp.EliteBoardTest do
  use ExUnit.Case, async: true

  alias ExVrp.EliteBoard

  defp board(start_index, behind) do
    EliteBoard.for_start(EliteBoard.new_table(), start_index, [0.5], behind, 1_000)
  end

  defp with_leader(board, start_index, cost) do
    EliteBoard.publish(%{board | start_index: start_index}, cost, {:solution_of, start_index})
    board
  end

  test "a start further behind the leader than its share follows the leader's best" do
    board = 0 |> board(0.05) |> with_leader(1, 100)

    assert EliteBoard.leader_to_follow(board, 106) == {:solution_of, 1}
  end

  test "a start within its share of the leader keeps its own search" do
    board = 0 |> board(0.05) |> with_leader(1, 100)

    assert EliteBoard.leader_to_follow(board, 105) == nil
  end

  test "the leader never follows itself" do
    board = 1 |> board(0.05) |> with_leader(1, 100)

    assert EliteBoard.leader_to_follow(board, 100) == nil
  end

  test "a start with nothing feasible follows any feasible leader" do
    board = 0 |> board(0.05) |> with_leader(1, 100)

    assert EliteBoard.leader_to_follow(board, :infinity) == {:solution_of, 1}
  end

  test "an infeasible leader is never followed" do
    board = 0 |> board(0.05) |> with_leader(1, :infinity)

    assert EliteBoard.leader_to_follow(board, :infinity) == nil
  end

  test "checkpoints become milliseconds into the search, in order" do
    board = EliteBoard.for_start(EliteBoard.new_table(), 0, [0.66, 0.33], 0.05, 300_000)

    assert board.checkpoints_ms == [99_000, 198_000]
  end
end

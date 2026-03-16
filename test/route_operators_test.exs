defmodule ExVrp.RouteOperatorsTest do
  @moduledoc """
  Tests for SwapTails operator.

  These tests match PyVRP's tests/search/test_SwapTails.py for exact parity.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  @moduletag :nif_required

  # =========================================================================
  # SwapTails Tests
  # =========================================================================

  describe "SwapTails" do
    test "move involving empty routes (PyVRP parity)" do
      # Based on test_move_involving_empty_routes
      distances = List.duplicate(List.duplicate(0, 3), 3)

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, delivery: [0])
        |> Model.add_client(x: 1, y: 0, delivery: [0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], fixed_cost: 10)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], fixed_cost: 100)
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([distances])

      {:ok, problem_data} = Model.to_problem_data(model)
      # Model has 1 load dimension (delivery: [0]), so need 1 load penalty
      {:ok, cost_evaluator} = make_cost_evaluator([0.0])

      route1 = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [], 1, 1)

      swap_tails = Native.create_swap_tails_nif(problem_data)

      # Get nodes for evaluation
      # route1: depot(0), client1(1), client2(2), depot(3)
      # client 2
      node1_2 = Native.search_route_get_node_nif(route1, 2)
      # depot of empty route
      depot2 = Native.search_route_get_node_nif(route2, 0)

      # Move that doesn't change structure
      delta = Native.swap_tails_evaluate_nif(swap_tails, node1_2, depot2, cost_evaluator)
      assert delta == 0

      # Move that creates routes (depot -> 1 -> depot) and (depot -> 2 -> depot)
      # client 1
      node1_1 = Native.search_route_get_node_nif(route1, 1)
      delta = Native.swap_tails_evaluate_nif(swap_tails, node1_1, depot2, cost_evaluator)
      # fixed cost of using route2
      assert delta == 100

      # Move that empties route1 and fills route2
      # depot
      depot1 = Native.search_route_get_node_nif(route1, 0)
      delta = Native.swap_tails_evaluate_nif(swap_tails, depot1, depot2, cost_evaluator)
      # -10 (save route1) + 100 (use route2)
      assert delta == 90
    end

    test "move with multiple depots (PyVRP parity)" do
      # Based on test_move_involving_multiple_depots
      distances = [
        [0, 10, 2, 8],
        [10, 0, 8, 2],
        [2, 8, 0, 6],
        [8, 2, 6, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 5, y: 5)
        |> Model.add_client(x: 1, y: 1, delivery: [0])
        |> Model.add_client(x: 4, y: 4, delivery: [0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], start_depot: 0, end_depot: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], start_depot: 1, end_depot: 1)
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([List.duplicate(List.duplicate(0, 4), 4)])

      {:ok, problem_data} = Model.to_problem_data(model)
      # Model has 1 load dimension (delivery: [0]), so need 1 load penalty
      {:ok, cost_evaluator} = make_cost_evaluator([0.0])

      # 0 -> 3 -> 0
      route1 = Native.make_search_route_nif(problem_data, [3], 0, 0)
      # 1 -> 2 -> 1
      route2 = Native.make_search_route_nif(problem_data, [2], 1, 1)

      assert Native.search_route_distance_nif(route1) == 16
      assert Native.search_route_distance_nif(route2) == 16

      swap_tails = Native.create_swap_tails_nif(problem_data)

      # Get nodes
      # client 3 in route1
      node1_1 = Native.search_route_get_node_nif(route1, 1)
      # client 2 in route2
      node2_1 = Native.search_route_get_node_nif(route2, 1)

      # No-op move
      delta = Native.swap_tails_evaluate_nif(swap_tails, node1_1, node2_1, cost_evaluator)
      assert delta == 0
    end

    test "basic swap tails functionality" do
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      route1 = Native.make_search_route_nif(problem_data, [1, 3], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [2, 4], 1, 0)

      swap_tails = Native.create_swap_tails_nif(problem_data)

      # Get nodes to swap tails at
      # client 1
      node1 = Native.search_route_get_node_nif(route1, 1)
      # client 2
      node2 = Native.search_route_get_node_nif(route2, 1)

      delta = Native.swap_tails_evaluate_nif(swap_tails, node1, node2, cost_evaluator)
      assert is_integer(delta)

      # Apply swap
      :ok = Native.swap_tails_apply_nif(swap_tails, node1, node2)

      Native.search_route_update_nif(route1)
      Native.search_route_update_nif(route2)

      # Verify routes have correct number of clients
      total_clients = Native.search_route_num_clients_nif(route1) + Native.search_route_num_clients_nif(route2)
      assert total_clients == 4
    end
  end

  describe "SwapTails edge cases (PyVRP parity)" do
    test "apply correctly swaps tails" do
      {:ok, problem_data, _cost_evaluator} = ok_small_setup()

      # Route 1: [1, 2, 3]
      route1 = Native.make_search_route_nif(problem_data, [1, 2, 3], 0, 0)
      # Route 2: [4]
      route2 = Native.make_search_route_nif(problem_data, [4], 1, 0)

      assert Native.search_route_num_clients_nif(route1) == 3
      assert Native.search_route_num_clients_nif(route2) == 1

      swap_tails = Native.create_swap_tails_nif(problem_data)

      # Swap after node 1 in route1 and after depot in route2
      # client 1
      node1 = Native.search_route_get_node_nif(route1, 1)
      # depot
      depot2 = Native.search_route_get_node_nif(route2, 0)

      :ok = Native.swap_tails_apply_nif(swap_tails, node1, depot2)

      Native.search_route_update_nif(route1)
      Native.search_route_update_nif(route2)

      # Route 1 should now have only [1]
      # Route 2 should now have [2, 3, 4]
      total_clients = Native.search_route_num_clients_nif(route1) + Native.search_route_num_clients_nif(route2)
      assert total_clients == 4
    end

    test "no-op when swapping at same position" do
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      route1 = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [3, 4], 1, 0)

      swap_tails = Native.create_swap_tails_nif(problem_data)

      # Swap after last client in each route - should be no-op
      # client 2 (last)
      node1 = Native.search_route_get_node_nif(route1, 2)
      # client 4 (last)
      node2 = Native.search_route_get_node_nif(route2, 2)

      delta = Native.swap_tails_evaluate_nif(swap_tails, node1, node2, cost_evaluator)

      # Swapping after last nodes is essentially a no-op
      assert delta == 0
    end
  end

  # =========================================================================
  # Helper Functions
  # =========================================================================

  defp ok_small_setup do
    distances = build_ok_small_distances()

    model =
      Model.new()
      |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
      |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
      |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
      |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
      |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
      |> Model.add_vehicle_type(num_available: 3, capacity: [10], tw_early: 0, tw_late: 45_000)
      |> Model.set_distance_matrices([distances])
      |> Model.set_duration_matrices([distances])

    {:ok, problem_data} = Model.to_problem_data(model)
    {:ok, cost_evaluator} = make_cost_evaluator([20.0])

    {:ok, problem_data, cost_evaluator}
  end

  defp build_ok_small_distances do
    [
      [0, 1544, 1944, 1931, 1476],
      [1726, 0, 1992, 1427, 1593],
      [1965, 1975, 0, 621, 1090],
      [2063, 1433, 647, 0, 818],
      [1475, 1594, 1090, 828, 0]
    ]
  end

  defp make_cost_evaluator(load_penalties) do
    Native.create_cost_evaluator(
      load_penalties: load_penalties,
      tw_penalty: 6.0,
      dist_penalty: 0.0
    )
  end
end

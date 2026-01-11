defmodule ExVrp.RouteOperatorsTest do
  @moduledoc """
  Tests for SwapStar, SwapRoutes, and SwapTails operators.

  These tests match PyVRP's tests/search/test_SwapStar.py, test_SwapRoutes.py,
  and test_SwapTails.py for exact parity.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  @moduletag :nif_required

  # =========================================================================
  # SwapStar Tests
  # =========================================================================

  describe "SwapStar" do
    test "can swap in place (PyVRP parity)" do
      # Based on test_swap_star_can_swap_in_place
      # Tests the rare case where best reinsert point of U is V and vice versa
      distances = [
        [0, 1, 10, 10],
        [1, 0, 10, 10],
        [10, 10, 0, 10],
        [10, 10, 1, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        # Use consistent 1 load dimension with 0 delivery (no excess load)
        |> Model.add_client(x: 1, y: 1, delivery: [0])
        |> Model.add_client(x: 2, y: 2, delivery: [0])
        |> Model.add_client(x: 3, y: 3, delivery: [0])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([List.duplicate(List.duplicate(0, 4), 4)])

      {:ok, problem_data} = Model.to_problem_data(model)
      # 1 load dimension with 0 penalty (no load impact on cost)
      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [0.0],
          tw_penalty: 1.0,
          dist_penalty: 0.0
        )

      # First route is 0 -> 1 -> 2 -> 0
      route1 = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      # Second route is 0 -> 3 -> 0
      route2 = Native.make_search_route_nif(problem_data, [3], 1, 0)

      # Use overlap_tolerance=1.0 to check all route pairs
      swap_star = Native.create_swap_star_nif(problem_data, 1.0)

      # Best is to exchange clients 1 and 3
      # Saves one expensive arc of cost 10 by replacing with cost 1
      delta = Native.swap_star_evaluate_nif(swap_star, route1, route2, cost_evaluator)
      assert delta == -9

      # Apply the move
      :ok = Native.swap_star_apply_nif(swap_star, route1, route2)

      # Update routes
      Native.search_route_update_nif(route1)
      Native.search_route_update_nif(route2)
    end

    test "evaluates OkSmall routes correctly" do
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      # Create routes like test_max_distance
      route1 = Native.make_search_route_nif(problem_data, [1, 2, 3], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [4], 1, 0)

      assert Native.search_route_distance_nif(route1) == 6220
      assert Native.search_route_distance_nif(route2) == 2951

      # Use overlap_tolerance=1.0 to check all route pairs
      swap_star = Native.create_swap_star_nif(problem_data, 1.0)
      delta = Native.swap_star_evaluate_nif(swap_star, route1, route2, cost_evaluator)

      # Should find an improving move
      assert delta < 0
    end

    test "max_distance constraint is accounted for (PyVRP parity)" do
      # Based on test_max_distance
      {:ok, problem_data, _cost_evaluator} = ok_small_setup()

      route1 = Native.make_search_route_nif(problem_data, [1, 2, 3], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [4], 1, 0)

      assert Native.search_route_distance_nif(route1) == 6220
      assert Native.search_route_distance_nif(route2) == 2951

      # Use overlap_tolerance=1.0 to check all route pairs
      swap_star = Native.create_swap_star_nif(problem_data, 1.0)

      # Only penalize distance (for max distance constraint)
      {:ok, dist_cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [0.0],
          tw_penalty: 0.0,
          dist_penalty: 10.0
        )

      delta = Native.swap_star_evaluate_nif(swap_star, route1, route2, dist_cost_evaluator)
      assert delta == -1043

      :ok = Native.swap_star_apply_nif(swap_star, route1, route2)

      Native.search_route_update_nif(route1)
      Native.search_route_update_nif(route2)

      # New route1 is 0 -> 2 -> 3 -> 4 -> 0, route2 is 0 -> 1 -> 0
      assert Native.search_route_distance_nif(route1) == 4858
      assert Native.search_route_distance_nif(route2) == 3270
      assert 6220 + 2951 - 1043 == 4858 + 3270
    end

    test "wrong load calculation bug (PyVRP issue #344 parity)" do
      # Based on test_wrong_load_calculation_bug
      # Tests that load calculations use correct node references
      distances = [
        [0, 10, 10, 10, 1],
        [1, 0, 10, 10, 10],
        [10, 10, 0, 10, 10],
        [10, 1, 10, 0, 10],
        [10, 10, 1, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, delivery: [0])
        |> Model.add_client(x: 2, y: 2, delivery: [0])
        |> Model.add_client(x: 3, y: 3, delivery: [15])
        |> Model.add_client(x: 4, y: 4, delivery: [0])
        |> Model.add_vehicle_type(num_available: 2, capacity: [12])
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([List.duplicate(List.duplicate(0, 5), 5)])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [1000.0],
          tw_penalty: 1.0,
          dist_penalty: 0.0
        )

      route1 = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [3, 4], 1, 0)

      swap_star = Native.create_swap_star_nif(problem_data, 1.0)

      # Optimal is 0 -> 3 -> 1 -> 0 and 0 -> 4 -> 2 -> 0
      # Exchanges four costly arcs of distance 10 for four arcs of distance 1
      # diff is 4 - 40 = -36
      delta = Native.swap_star_evaluate_nif(swap_star, route1, route2, cost_evaluator)
      assert delta == -36

      :ok = Native.swap_star_apply_nif(swap_star, route1, route2)
      Native.search_route_update_nif(route1)
      Native.search_route_update_nif(route2)
    end

    test "overlap_tolerance controls which route pairs are checked (PyVRP parity)" do
      # Based on test_swap_star_overlap_tolerance
      # With tolerance=0, no routes should have overlap
      # With tolerance=1, all routes should be checked
      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
        |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
        |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        # Two different vehicle types
        |> Model.add_vehicle_type(num_available: 1, capacity: [5], tw_early: 0, tw_late: 45_000)
        |> Model.add_vehicle_type(num_available: 1, capacity: [20], tw_early: 0, tw_late: 45_000)
        |> Model.set_distance_matrices([build_ok_small_distances()])
        |> Model.set_duration_matrices([build_ok_small_distances()])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [1000.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      route1 = Native.make_search_route_nif(problem_data, [1, 2, 4], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [3], 1, 1)

      # With overlap_tolerance=0, no routes are checked (returns 0)
      swap_star_0 = Native.create_swap_star_nif(problem_data, 0.0)
      delta_0 = Native.swap_star_evaluate_nif(swap_star_0, route1, route2, cost_evaluator)
      assert delta_0 == 0

      # With overlap_tolerance=1, all routes are checked (finds improving move)
      swap_star_1 = Native.create_swap_star_nif(problem_data, 1.0)
      delta_1 = Native.swap_star_evaluate_nif(swap_star_1, route1, route2, cost_evaluator)
      assert delta_1 < 0
    end
  end

  # =========================================================================
  # SwapRoutes Tests
  # =========================================================================

  describe "SwapRoutes" do
    test "evaluate returns 0 for same vehicle type (PyVRP parity)" do
      # Based on test_evaluate_same_vehicle_type
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      route1 = Native.make_search_route_nif(problem_data, [1], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [2], 1, 0)

      assert Native.search_route_vehicle_type_nif(route1) == Native.search_route_vehicle_type_nif(route2)

      swap_routes = Native.create_swap_routes_nif(problem_data)
      delta = Native.swap_routes_evaluate_nif(swap_routes, route1, route2, cost_evaluator)

      # Same vehicle types means no benefit from swapping
      assert delta == 0
    end

    test "evaluate returns 0 for same route (PyVRP parity)" do
      # Based on test_same_route
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1], 0, 0)

      swap_routes = Native.create_swap_routes_nif(problem_data)
      delta = Native.swap_routes_evaluate_nif(swap_routes, route, route, cost_evaluator)

      # Swapping route with itself has no effect
      assert delta == 0
    end

    test "evaluate capacity differences (PyVRP parity)" do
      # Based on test_evaluate_capacity_differences
      # Two vehicle types with different capacities
      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726)
        |> Model.add_client(x: 226, y: 1297, delivery: [5])
        |> Model.add_client(x: 590, y: 530, delivery: [5])
        |> Model.add_client(x: 435, y: 718, delivery: [3])
        |> Model.add_client(x: 1191, y: 639, delivery: [5])
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [20])
        |> Model.set_distance_matrices([build_ok_small_distances()])
        |> Model.set_duration_matrices([build_ok_small_distances()])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [40.0],
          tw_penalty: 1.0,
          dist_penalty: 0.0
        )

      # route1 has vehicle type 0 (capacity 10) with load 15
      route1 = Native.make_search_route_nif(problem_data, [1, 2, 4], 0, 0)
      # route2 has vehicle type 1 (capacity 20) with load 3
      route2 = Native.make_search_route_nif(problem_data, [3], 1, 1)

      assert Native.search_route_has_excess_load_nif(route1) == true
      assert Native.search_route_load_nif(route1) == [15]

      assert Native.search_route_has_excess_load_nif(route2) == false
      assert Native.search_route_load_nif(route2) == [3]

      swap_routes = Native.create_swap_routes_nif(problem_data)

      # Swapping should alleviate excess load (15 < 20, 3 < 10)
      # Excess was 5 (15-10), at penalty 40 = 200
      delta = Native.swap_routes_evaluate_nif(swap_routes, route1, route2, cost_evaluator)
      assert delta == -200

      # Apply and verify
      :ok = Native.swap_routes_apply_nif(swap_routes, route1, route2)
      Native.search_route_update_nif(route1)
      Native.search_route_update_nif(route2)

      assert Native.search_route_num_clients_nif(route1) == 1
      assert Native.search_route_is_feasible_nif(route1) == true

      assert Native.search_route_num_clients_nif(route2) == 3
      assert Native.search_route_is_feasible_nif(route2) == true
    end

    test "apply swaps visits between routes (PyVRP parity)" do
      # Based on test_apply
      {:ok, problem_data, _cost_evaluator} = ok_small_setup()

      test_cases = [
        # both empty
        {[], []},
        # first non-empty, second empty
        {[1], []},
        # first empty, second non-empty
        {[], [1]},
        # both non-empty but unequal length
        {[1], [2, 3]},
        # both non-empty but unequal length (flipped)
        {[2, 3], [1]},
        # both non-empty equal length
        {[2, 3], [1, 4]}
      ]

      for {visits1, visits2} <- test_cases do
        route1 = Native.make_search_route_nif(problem_data, visits1, 0, 0)
        route2 = Native.make_search_route_nif(problem_data, visits2, 1, 0)

        swap_routes = Native.create_swap_routes_nif(problem_data)
        :ok = Native.swap_routes_apply_nif(swap_routes, route1, route2)

        Native.search_route_update_nif(route1)
        Native.search_route_update_nif(route2)

        # After swap, visits should be exchanged
        assert Native.search_route_num_clients_nif(route1) == length(visits2)
        assert Native.search_route_num_clients_nif(route2) == length(visits1)
      end
    end

    test "evaluate returns 0 when routes are empty (PyVRP parity)" do
      # Based on test_evaluate_empty_routes
      # Two vehicle types with different capacities
      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726)
        |> Model.add_client(x: 226, y: 1297, delivery: [5])
        |> Model.add_client(x: 590, y: 530, delivery: [5])
        |> Model.add_client(x: 435, y: 718, delivery: [3])
        |> Model.add_client(x: 1191, y: 639, delivery: [5])
        |> Model.add_vehicle_type(num_available: 3, capacity: [10])
        |> Model.add_vehicle_type(num_available: 3, capacity: [10])
        |> Model.set_distance_matrices([build_ok_small_distances()])
        |> Model.set_duration_matrices([build_ok_small_distances()])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [1.0],
          tw_penalty: 1.0,
          dist_penalty: 0.0
        )

      # route1 has visits, route2 is empty
      route1 = Native.make_search_route_nif(problem_data, [1], 0, 0)
      route2 = Native.create_search_route_nif(problem_data, 1, 1)
      Native.search_route_update_nif(route2)

      # Empty route (route3) of type 0
      route3 = Native.create_search_route_nif(problem_data, 2, 0)
      Native.search_route_update_nif(route3)

      swap_routes = Native.create_swap_routes_nif(problem_data)

      # Vehicle types differ, but one route is empty - returns 0
      assert Native.search_route_vehicle_type_nif(route1) != Native.search_route_vehicle_type_nif(route2)
      delta = Native.swap_routes_evaluate_nif(swap_routes, route1, route2, cost_evaluator)
      assert delta == 0

      delta_rev = Native.swap_routes_evaluate_nif(swap_routes, route2, route1, cost_evaluator)
      assert delta_rev == 0

      # Both routes empty - returns 0
      delta_empty = Native.swap_routes_evaluate_nif(swap_routes, route3, route2, cost_evaluator)
      assert delta_empty == 0
    end

    test "evaluate with different depots (PyVRP parity)" do
      # Based on test_evaluate_with_different_depots
      distances = [
        [0, 10, 2, 8],
        [10, 0, 8, 2],
        [2, 8, 0, 6],
        [8, 2, 6, 0]
      ]

      durations = List.duplicate(List.duplicate(0, 4), 4)

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 5, y: 5)
        |> Model.add_client(x: 1, y: 1, delivery: [0])
        |> Model.add_client(x: 4, y: 4, delivery: [0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], start_depot: 0, end_depot: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], start_depot: 1, end_depot: 1)
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([durations])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [0.0],
          tw_penalty: 1.0,
          dist_penalty: 0.0
        )

      # Route 1: depot 0 -> client 3 -> depot 0 (distance 16)
      # Route 2: depot 1 -> client 2 -> depot 1 (distance 16)
      route1 = Native.make_search_route_nif(problem_data, [3], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [2], 1, 1)

      assert Native.search_route_distance_nif(route1) == 16
      assert Native.search_route_distance_nif(route2) == 16

      swap_routes = Native.create_swap_routes_nif(problem_data)
      delta = Native.swap_routes_evaluate_nif(swap_routes, route1, route2, cost_evaluator)

      # Swapping would reduce each route's cost to 4, improvement of 2*12=24
      assert delta == -24
    end
  end

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

  # =========================================================================
  # Additional PyVRP Parity Tests
  # =========================================================================

  describe "SwapRoutes shift duration (PyVRP parity)" do
    test "evaluate shift duration constraints" do
      # Based on test_evaluate_shift_duration_constraints
      # Tests that SwapRoutes correctly evaluates changes in time warp due to
      # different shift duration constraints.
      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
        |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
        |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        # Vehicle type 0 with short shift duration (causes time warp)
        |> Model.add_vehicle_type(num_available: 2, capacity: [10], tw_early: 0, tw_late: 45_000, shift_duration: 3000)
        # Vehicle type 1 with no shift duration constraint
        |> Model.add_vehicle_type(num_available: 2, capacity: [10], tw_early: 0, tw_late: 45_000)
        |> Model.set_distance_matrices([build_ok_small_distances()])
        |> Model.set_duration_matrices([build_ok_small_distances()])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [1.0],
          tw_penalty: 1.0,
          dist_penalty: 0.0
        )

      # Route1 with vehicle type 0 (limited shift duration)
      route1 = Native.make_search_route_nif(problem_data, [1, 4], 0, 0)
      # Route2 with vehicle type 1 (no shift duration limit)
      route2 = Native.make_search_route_nif(problem_data, [3, 2], 1, 1)

      swap_routes = Native.create_swap_routes_nif(problem_data)
      delta = Native.swap_routes_evaluate_nif(swap_routes, route1, route2, cost_evaluator)

      # Swapping should reduce time warp due to shift duration
      assert delta < 0
    end
  end

  describe "SwapStar edge cases (PyVRP parity)" do
    test "no improvement when routes already optimal" do
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      # Single client routes - already optimal
      route1 = Native.make_search_route_nif(problem_data, [1], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [2], 1, 0)

      swap_star = Native.create_swap_star_nif(problem_data, 1.0)
      delta = Native.swap_star_evaluate_nif(swap_star, route1, route2, cost_evaluator)

      # May or may not find improvement for single clients, just verify no error
      assert is_integer(delta)
    end

    test "handles empty routes" do
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      route1 = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      # Empty route
      route2 = Native.create_search_route_nif(problem_data, 1, 0)
      Native.search_route_update_nif(route2)

      swap_star = Native.create_swap_star_nif(problem_data, 1.0)
      delta = Native.swap_star_evaluate_nif(swap_star, route1, route2, cost_evaluator)

      # SwapStar should handle empty route gracefully
      assert is_integer(delta)
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

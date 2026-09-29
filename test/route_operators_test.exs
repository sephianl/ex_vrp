defmodule ExVrp.RouteOperatorsTest do
  @moduledoc """
  Tests for the SwapRoutes and SwapTails operators.

  These tests match PyVRP's tests/search/test_SwapRoutes.py and
  test_SwapTails.py for exact parity.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  @moduletag :nif_required

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
        |> Model.add_depot([])
        |> Model.add_client(delivery: [5])
        |> Model.add_client(delivery: [5])
        |> Model.add_client(delivery: [3])
        |> Model.add_client(delivery: [5])
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
        |> Model.add_depot([])
        |> Model.add_client(delivery: [5])
        |> Model.add_client(delivery: [5])
        |> Model.add_client(delivery: [3])
        |> Model.add_client(delivery: [5])
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
        |> Model.add_depot([])
        |> Model.add_depot([])
        |> Model.add_client(delivery: [0])
        |> Model.add_client(delivery: [0])
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
        |> Model.add_depot([])
        |> Model.add_client(delivery: [0])
        |> Model.add_client(delivery: [0])
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
        |> Model.add_depot([])
        |> Model.add_depot([])
        |> Model.add_client(delivery: [0])
        |> Model.add_client(delivery: [0])
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
        |> Model.add_depot(tw_early: 0, tw_late: 45_000)
        |> Model.add_client(delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
        |> Model.add_client(delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_client(delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
        |> Model.add_client(delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        # Vehicle type 0 with short shift duration (causes time warp)
        |> Model.add_vehicle_type(num_available: 2, capacity: [10], time_windows: [{0, 45_000}], shift_duration: 3000)
        # Vehicle type 1 with no shift duration constraint
        |> Model.add_vehicle_type(num_available: 2, capacity: [10], time_windows: [{0, 45_000}])
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

  describe "max_drive delta consistency" do
    # Proposal::duration() (the delta path insert_cost_nif exercises) computes
    # endTime and overtime from ds.timeWarp(maxDuration) alone, and only adds
    # the drive excess to the returned time-warp component afterwards.
    # Route::update() must fold max_drive's excess into timeWarp_ the same
    # way, or local search would price a move differently from what applying
    # it actually produces, and the two would fight over the route forever.
    defp max_drive_problem do
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(delivery: [0])
        |> Model.add_client(delivery: [0])
        |> Model.add_client(delivery: [0])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          unit_distance_cost: 0,
          max_drive: 100
        )
        |> Model.set_euclidean_matrices([{0, 0}, {20, 0}, {40, 0}, {90, 0}])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(load_penalties: [0.0], tw_penalty: 1.0, dist_penalty: 0.0)

      {problem_data, cost_evaluator}
    end

    test "an evaluated insert's time-warp delta matches the rebuilt route" do
      {problem_data, cost_evaluator} = max_drive_problem()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      after_client_2 = Native.search_route_get_node_nif(route, 2)
      client_3 = Native.create_search_node_nif(problem_data, 3)

      delta = Native.insert_cost_nif(client_3, after_client_2, problem_data, cost_evaluator)

      before_time_warp = Native.search_route_time_warp_nif(route)

      after_route = Native.make_search_route_nif(problem_data, [1, 2, 3], 0, 0)
      after_time_warp = Native.search_route_time_warp_nif(after_route)

      assert delta == after_time_warp - before_time_warp
    end

    defp max_drive_overtime_problem do
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(delivery: [0])
        |> Model.add_client(delivery: [0])
        |> Model.add_client(delivery: [0])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          unit_distance_cost: 0,
          max_drive: 150,
          max_duration: :infinity,
          shift_duration: 150,
          unit_overtime_cost: 1
        )
        |> Model.set_euclidean_matrices([{0, 0}, {50, 0}, {100, 0}, {250, 0}])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(load_penalties: [0.0], tw_penalty: 1.0, dist_penalty: 0.0)

      {problem_data, cost_evaluator}
    end

    defp max_drive_forbidden_window_problem do
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(delivery: [0])
        |> Model.add_client(delivery: [0])
        |> Model.add_client(delivery: [0])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          unit_distance_cost: 0,
          max_drive: 150,
          max_duration: :infinity,
          time_windows: [{0, 30}, {130, 10_000}]
        )
        |> Model.set_euclidean_matrices([{0, 0}, {50, 0}, {100, 0}, {250, 0}])

      {:ok, problem_data} = Model.to_problem_data(model)

      problem_data
    end

    test "the delta still matches when both routes already exceed the cap and overtime applies" do
      # The test above only covers a move from zero excess to positive excess,
      # with no overtime — here both the before and after routes already
      # exceed max_drive, and shift_duration/unit_overtime_cost are set, so a
      # nonzero timeWarpDS_ is subtracted and overtimeDS feeds durationCostDS_
      # on both sides of the delta.
      {problem_data, cost_evaluator} = max_drive_overtime_problem()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      after_client_2 = Native.search_route_get_node_nif(route, 2)
      client_3 = Native.create_search_node_nif(problem_data, 3)

      delta = Native.insert_cost_nif(client_3, after_client_2, problem_data, cost_evaluator)

      before_time_warp = Native.search_route_time_warp_nif(route)
      before_duration_cost = Native.search_route_duration_cost_nif(route)
      assert before_time_warp > 0
      assert before_duration_cost > 0

      after_route = Native.make_search_route_nif(problem_data, [1, 2, 3], 0, 0)
      after_time_warp = Native.search_route_time_warp_nif(after_route)
      after_duration_cost = Native.search_route_duration_cost_nif(after_route)

      assert delta ==
               after_duration_cost - before_duration_cost + (after_time_warp - before_time_warp)
    end
  end

  describe "search::Route.timelineTimeWarp() excludes drive excess" do
    # Solution.cpp's multi-trip insertion feasibility check derives the depot
    # return time (the "trip boundary") from timelineTimeWarp() rather than
    # timeWarp(), because drive excess is a penalty folded into timeWarp()
    # that does not shift the timeline. These tests call the C++ accessor
    # directly and check it against an independently known drive excess,
    # rather than recomputing the subtraction in Elixir.
    #
    # Depot -> client 1 (50) -> client 2 (100) -> depot (100): 50 + 50 + 100
    # = 200 of travel against max_drive: 150, so drive excess is 50 either
    # way — it depends only on total travel and the cap, not on forbidden
    # windows.
    test "on a capped route with no forbidden windows, it equals time_warp - drive_excess" do
      {problem_data, _cost_evaluator} = max_drive_overtime_problem()

      # Nothing else on this route produces time warp (max_duration:
      # :infinity, wide open time windows), so time_warp is entirely drive
      # excess and timelineTimeWarp is 0.
      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)

      time_warp = Native.search_route_time_warp_nif(route)
      drive_excess = 50

      assert time_warp == drive_excess
      assert Native.search_route_timeline_time_warp_nif(route) == time_warp - drive_excess
    end

    test "on a capped route with forbidden windows, it equals time_warp - drive_excess" do
      problem_data = max_drive_forbidden_window_problem()

      # The forbidden window [30, 130) is straddled by the arrival at client 1
      # (at t=50, since it starts driving at t=0), which adds 80 of timeWarp
      # (the delay of forcing that arrival to t=130) on top of the 50 of
      # drive excess above.
      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)

      time_warp = Native.search_route_time_warp_nif(route)
      drive_excess = 50

      assert time_warp == 130

      assert Native.search_route_timeline_time_warp_nif(route) == time_warp - drive_excess
      assert Native.search_route_timeline_time_warp_nif(route) == 80
    end
  end

  # =========================================================================
  # Helper Functions
  # =========================================================================

  defp ok_small_setup do
    distances = build_ok_small_distances()

    model =
      Model.new()
      |> Model.add_depot(tw_early: 0, tw_late: 45_000)
      |> Model.add_client(delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
      |> Model.add_client(delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
      |> Model.add_client(delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
      |> Model.add_client(delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
      |> Model.add_vehicle_type(num_available: 3, capacity: [10], time_windows: [{0, 45_000}])
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

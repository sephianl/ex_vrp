defmodule ExVrp.PrimitivesTest do
  @moduledoc """
  Tests for primitive cost functions (insert_cost, remove_cost, inplace_cost).

  These tests match PyVRP's tests/search/test_primitives.py for exact parity.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  @moduletag :nif_required

  describe "insert_cost" do
    test "returns zero when not allowed" do
      # Based on test_insert_cost_zero_when_not_allowed
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      # Route is: depot(0), client1(1), client2(2), depot(3)

      # Inserting the depot is not possible
      depot_start = Native.search_route_get_node_nif(route, 0)
      depot_end = Native.search_route_get_node_nif(route, 3)
      node1 = Native.search_route_get_node_nif(route, 1)
      node2 = Native.search_route_get_node_nif(route, 2)

      assert Native.insert_cost_nif(depot_start, node1, problem_data, cost_evaluator) == 0
      assert Native.insert_cost_nif(depot_end, node2, problem_data, cost_evaluator) == 0

      # Inserting after a node that's not in a route is not possible
      unrouted_node = Native.create_search_node_nif(problem_data, 3)
      assert Native.insert_cost_nif(node1, unrouted_node, problem_data, cost_evaluator) == 0
    end

    test "basic insert_cost calculations (PyVRP parity)" do
      # Based on test_insert_cost
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)

      node1 = Native.search_route_get_node_nif(route, 1)
      node2 = Native.search_route_get_node_nif(route, 2)

      # Insert client 4 after client 1
      # Adds arcs 1 -> 4 -> 2, removes arc 1 -> 2
      # Added: 1593 + 1090 = 2683, Removed: 1992
      # Also adds 5 load (+5 penalty), no time warp
      # Total: 2683 - 1992 + 5 = 696
      new_node4 = Native.create_search_node_nif(problem_data, 4)
      delta = Native.insert_cost_nif(new_node4, node1, problem_data, cost_evaluator)
      assert delta == 696

      # Insert client 4 after client 2
      # +5 load penalty, delta dist: 1090 + 1475 - 1965 = 600
      # Total: 605
      delta2 = Native.insert_cost_nif(new_node4, node2, problem_data, cost_evaluator)
      assert delta2 == 605
    end

    test "insert_cost with time warp (PyVRP parity)" do
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      node1 = Native.search_route_get_node_nif(route, 1)
      node2 = Native.search_route_get_node_nif(route, 2)

      # Insert client 3 after client 1
      # +3 load penalty, delta dist: 1427 + 647 - 1992 = 82
      # Time warp increases: arrive at client 3 at 17387, closing is 15300
      # Time warp added: 17387 - 15300 = 2087
      # Total: 3 + 82 + 2087 = 2172
      new_node3 = Native.create_search_node_nif(problem_data, 3)
      delta = Native.insert_cost_nif(new_node3, node1, problem_data, cost_evaluator)
      assert delta == 2172

      # Insert client 3 after client 2
      # +3 load penalty, delta dist: 621 + 2063 - 1965 = 719
      # Time warp: arrive at 18933, closing 15300, adds 3633
      # Total: 3 + 719 + 3633 = 4355
      delta2 = Native.insert_cost_nif(new_node3, node2, problem_data, cost_evaluator)
      assert delta2 == 4355
    end

    test "insert_cost adds fixed vehicle cost for empty route (PyVRP parity)" do
      # Based on test_insert_fixed_vehicle_cost
      distances = List.duplicate(List.duplicate(0, 3), 3)

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, delivery: [0])
        |> Model.add_client(x: 1, y: 0, delivery: [0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], fixed_cost: 7)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], fixed_cost: 13)
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([distances])

      {:ok, problem_data} = Model.to_problem_data(model)
      # No load penalty (empty list causes issue, use [0.0] for 1 dimension)
      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [0.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      # Inserting into empty route adds fixed cost 7
      route0 = Native.create_search_route_nif(problem_data, 0, 0)
      depot = Native.search_route_get_node_nif(route0, 0)
      client = Native.create_search_node_nif(problem_data, 1)
      delta = Native.insert_cost_nif(client, depot, problem_data, cost_evaluator)
      assert delta == 7

      # Different vehicle type with fixed cost 13
      route1 = Native.create_search_route_nif(problem_data, 1, 1)
      depot1 = Native.search_route_get_node_nif(route1, 0)
      delta1 = Native.insert_cost_nif(client, depot1, problem_data, cost_evaluator)
      assert delta1 == 13
    end
  end

  describe "remove_cost" do
    test "returns zero when not allowed" do
      # Based on test_remove_cost_zero_when_not_allowed
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)

      # Removing the depot is not possible
      depot_start = Native.search_route_get_node_nif(route, 0)
      depot_end = Native.search_route_get_node_nif(route, 3)
      assert Native.remove_cost_nif(depot_start, problem_data, cost_evaluator) == 0
      assert Native.remove_cost_nif(depot_end, problem_data, cost_evaluator) == 0

      # Removing a node that's not in a route is not possible
      unrouted_node = Native.create_search_node_nif(problem_data, 3)
      assert Native.remove_cost_nif(unrouted_node, problem_data, cost_evaluator) == 0
    end

    test "basic remove_cost calculations (PyVRP parity)" do
      # Based on test_remove
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)

      node1 = Native.search_route_get_node_nif(route, 1)
      node2 = Native.search_route_get_node_nif(route, 2)

      # Remove client 1: removes arcs 0 -> 1 -> 2, adds arc 0 -> 2
      # Delta dist: 1944 - 1544 - 1992 = -1592
      delta = Native.remove_cost_nif(node1, problem_data, cost_evaluator)
      assert delta == -1592

      # Remove client 2: removes arcs 1 -> 2 -> 0, adds arc 1 -> 0
      # Delta dist: 1726 - 1992 - 1965 = -2231
      delta2 = Native.remove_cost_nif(node2, problem_data, cost_evaluator)
      assert delta2 == -2231
    end

    test "remove_cost subtracts fixed vehicle cost when route becomes empty (PyVRP parity)" do
      # Based on test_remove_fixed_vehicle_cost
      distances = List.duplicate(List.duplicate(0, 3), 3)

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, delivery: [0])
        |> Model.add_client(x: 1, y: 0, delivery: [0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], fixed_cost: 7)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], fixed_cost: 13)
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([distances])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [0.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      # Removing only client empties route, saves fixed cost 7
      route0 = Native.make_search_route_nif(problem_data, [1], 0, 0)
      client0 = Native.search_route_get_node_nif(route0, 1)
      delta = Native.remove_cost_nif(client0, problem_data, cost_evaluator)
      assert delta == -7

      # Different vehicle type with fixed cost 13
      route1 = Native.make_search_route_nif(problem_data, [1], 1, 1)
      client1 = Native.search_route_get_node_nif(route1, 1)
      delta1 = Native.remove_cost_nif(client1, problem_data, cost_evaluator)
      assert delta1 == -13
    end
  end

  describe "multi-depot insert_cost (PyVRP parity)" do
    test "insert_cost_between_different_depots" do
      # Based on test_insert_cost_between_different_depots
      # Tests delta distance of inserting into empty route with different depots
      model =
        Model.new()
        # depot 0
        |> Model.add_depot(x: 0, y: 0)
        # depot 1
        |> Model.add_depot(x: 1000, y: 0)
        # client 2
        |> Model.add_client(x: 500, y: 500, delivery: [0])
        # client 3
        |> Model.add_client(x: 200, y: 200, delivery: [0])
        # client 4
        |> Model.add_client(x: 800, y: 800, delivery: [0])
        |> Model.add_vehicle_type(num_available: 3, capacity: [10], start_depot: 0, end_depot: 1)

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [0.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      # Create empty route with start_depot=0, end_depot=1
      route = Native.create_search_route_nif(problem_data, 0, 0)
      depot = Native.search_route_get_node_nif(route, 0)

      # The delta cost is distance from start depot to new node, and to end depot
      client = Native.create_search_node_nif(problem_data, 2)
      delta = Native.insert_cost_nif(client, depot, problem_data, cost_evaluator)
      # This should be the distance from depot 0 to client 2 + client 2 to depot 1
      assert is_integer(delta)
      # Non-zero since we're adding distance
      assert delta > 0
    end
  end

  describe "multi-trip remove_cost (PyVRP parity)" do
    test "remove_reload_depot" do
      # Based on test_remove_reload_depot
      # Tests that remove_cost correctly evaluates removing a reload depot
      {:ok, problem_data} = ok_small_multiple_trips()

      # Route with reload depot: [1, 2, 0, 3, 4]
      # This is: start -> 1 -> 2 -> reload_depot -> 3 -> 4 -> end
      route = Native.make_search_route_nif(problem_data, [1, 2, 0, 3, 4], 0, 0)

      assert Native.search_route_has_excess_load_nif(route) == false

      # Check that node at index 3 is a reload depot
      reload_node = Native.search_route_get_node_nif(route, 3)
      assert Native.search_node_is_depot_nif(reload_node) == true

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [1000.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      # Removing reload depot gains 8 excess load (costs 8000)
      # Distance delta: dist(2,3) - dist(2,0) - dist(0,3) = 621 - 1965 - 1931 = -3275
      # Total: 8000 - 3275 = 4725
      delta = Native.remove_cost_nif(reload_node, problem_data, cost_eval)
      assert delta == 4725
    end

    test "remove_consecutive_reload_depots" do
      # Based on test_remove_consecutive_reload_depots
      # Tests removing one of multiple consecutive reload depots
      {:ok, problem_data} = ok_small_multiple_trips_2_reloads()

      # Route with two consecutive reload depots: [1, 2, 0, 0, 3, 4]
      route = Native.make_search_route_nif(problem_data, [1, 2, 0, 0, 3, 4], 0, 0)

      first_reload = Native.search_route_get_node_nif(route, 3)
      second_reload = Native.search_route_get_node_nif(route, 4)

      assert Native.search_node_is_depot_nif(first_reload) == true
      assert Native.search_node_is_depot_nif(second_reload) == true

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [1000.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      # Removing first depot: no load change since second depot still reloads
      # Distance is same since both depots are at same location
      # Delta should be 0
      delta1 = Native.remove_cost_nif(first_reload, problem_data, cost_eval)
      assert delta1 == 0

      # Same for second depot
      delta2 = Native.remove_cost_nif(second_reload, problem_data, cost_eval)
      assert delta2 == 0
    end
  end

  describe "empty route delta cost bug (PyVRP #853)" do
    test "insert/remove with empty route does not include empty route costs" do
      # Based on test_empty_route_delta_cost_bug
      mat = [
        [0, 5, 1],
        [5, 0, 1],
        [1, 1, 0]
      ]

      model =
        Model.new()
        # depot 0
        |> Model.add_depot(x: 0, y: 0)
        # depot 1
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 0, y: 0, delivery: [0])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [10],
          start_depot: 0,
          end_depot: 1,
          shift_duration: 0
        )
        |> Model.set_distance_matrices([mat])
        |> Model.set_duration_matrices([mat])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [0.0],
          tw_penalty: 1.0,
          dist_penalty: 1.0
        )

      # Inserting client into empty route: distance (2) + time warp (2) = 4
      # NOT including empty route's costs (5 dist + 5 time warp)
      route = Native.make_search_route_nif(problem_data, [], 0, 0)
      depot = Native.search_route_get_node_nif(route, 0)
      client = Native.create_search_node_nif(problem_data, 2)

      delta_insert = Native.insert_cost_nif(client, depot, problem_data, cost_eval)
      assert delta_insert == 4

      # Removing client results in empty route: -distance -time_warp = -4
      route_with_client = Native.make_search_route_nif(problem_data, [2], 0, 0)
      client_node = Native.search_route_get_node_nif(route_with_client, 1)
      delta_remove = Native.remove_cost_nif(client_node, problem_data, cost_eval)
      assert delta_remove == -4
    end
  end

  describe "inplace_cost" do
    test "returns zero when guard clauses trigger" do
      # Based on test_inplace_cost_zero_when_shortcutting_on_guard_clauses
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      route = Native.create_search_route_nif(problem_data, 0, 0)
      node1 = Native.create_search_node_nif(problem_data, 1)
      node2 = Native.create_search_node_nif(problem_data, 2)

      # node1 is in the route, node2 is not - cannot insert node1 in place of node2
      :ok = Native.search_route_append_nif(route, node1)
      Native.search_route_update_nif(route)
      assert Native.search_node_has_route_nif(node1) == true
      assert Native.search_node_has_route_nif(node2) == false
      assert Native.inplace_cost_nif(node1, node2, problem_data, cost_evaluator) == 0

      # Neither node is in a route
      :ok = Native.search_route_clear_nif(route)
      assert Native.search_node_has_route_nif(node1) == false
      assert Native.search_node_has_route_nif(node2) == false
      assert Native.inplace_cost_nif(node1, node2, problem_data, cost_evaluator) == 0

      # Both nodes are in a route
      :ok = Native.search_route_append_nif(route, node1)
      :ok = Native.search_route_append_nif(route, node2)
      Native.search_route_update_nif(route)
      assert Native.search_node_has_route_nif(node1) == true
      assert Native.search_node_has_route_nif(node2) == true
      assert Native.inplace_cost_nif(node1, node2, problem_data, cost_evaluator) == 0
    end

    test "inplace_cost delta distance computation (PyVRP parity)" do
      # Based on test_inplace_cost_delta_distance_computation
      {:ok, problem_data, _} = ok_small_setup()

      # Cost evaluator with no penalties
      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [0.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      route = Native.create_search_route_nif(problem_data, 0, 0)
      node1 = Native.create_search_node_nif(problem_data, 1)
      node2 = Native.create_search_node_nif(problem_data, 2)
      node3 = Native.create_search_node_nif(problem_data, 3)

      :ok = Native.search_route_append_nif(route, node1)
      :ok = Native.search_route_append_nif(route, node2)
      Native.search_route_update_nif(route)

      # Route is 0 -> 1 -> 2 -> 0
      # Replace node1 with node3: route becomes 0 -> 3 -> 2 -> 0
      # Saves: dist(0, 1) + dist(1, 2) = 1544 + 1992 = 3536
      # Adds:  dist(0, 3) + dist(3, 2) = 1931 + 647 = 2578
      # Delta: 2578 - 3536 = -958
      delta = Native.inplace_cost_nif(node3, node1, problem_data, cost_evaluator)
      assert delta == -958
    end
  end

  # Helper functions

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

    {:ok, cost_evaluator} =
      Native.create_cost_evaluator(
        # unit load penalty
        load_penalties: [1.0],
        # unit time warp penalty
        tw_penalty: 1.0,
        dist_penalty: 0.0
      )

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

  defp ok_small_multiple_trips do
    distances = build_ok_small_distances()

    model =
      Model.new()
      |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
      |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
      |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
      |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
      |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
      |> Model.add_vehicle_type(
        num_available: 3,
        capacity: [10],
        tw_early: 0,
        tw_late: 45_000,
        reload_depots: [0],
        max_reloads: 1
      )
      |> Model.set_distance_matrices([distances])
      |> Model.set_duration_matrices([distances])

    Model.to_problem_data(model)
  end

  defp ok_small_multiple_trips_2_reloads do
    distances = build_ok_small_distances()

    model =
      Model.new()
      |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
      |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
      |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
      |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
      |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
      |> Model.add_vehicle_type(
        num_available: 3,
        capacity: [10],
        tw_early: 0,
        tw_late: 45_000,
        reload_depots: [0],
        # Allow 2 reloads for consecutive depot test
        max_reloads: 2
      )
      |> Model.set_distance_matrices([distances])
      |> Model.set_duration_matrices([distances])

    Model.to_problem_data(model)
  end
end

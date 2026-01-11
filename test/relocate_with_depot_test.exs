defmodule ExVrp.RelocateWithDepotTest do
  @moduledoc """
  Tests for RelocateWithDepot operator.

  These tests match PyVRP's tests/search/test_RelocateWithDepot.py for exact parity.
  RelocateWithDepot is a local search operator that relocates a node and inserts
  a reload depot along with the relocation (used for multi-trip VRP).
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  @moduletag :nif_required

  describe "RelocateWithDepot single route (PyVRP parity)" do
    test "inserts depot single route - test_inserts_depot_single_route" do
      # Tests that RelocateWithDepot inserts a reload depot along with the node
      # relocation in the same route.
      {:ok, problem_data} = ok_small_multiple_trips()

      route = Native.make_search_route_nif(problem_data, [1, 2, 3, 4], 0, 0)

      assert Native.search_route_num_clients_nif(route) == 4
      # start + end
      assert Native.search_route_num_depots_nif(route) == 2
      assert Native.search_route_num_trips_nif(route) == 1
      assert Native.search_route_excess_load_nif(route) == [8]

      op = Native.create_relocate_with_depot_nif(problem_data)

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [500.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      # Get nodes for evaluation: node at index 2 (client 2) and node at index 3 (client 3)
      node2 = Native.search_route_get_node_nif(route, 2)
      node3 = Native.search_route_get_node_nif(route, 3)

      # The route now is 1 2 3 4, proposal evaluates 1 3 | 2 4 and 1 3 2 | 4.
      # The move resulting in 1 3 | 2 4 is better. PyVRP expects delta = -907
      delta = Native.relocate_with_depot_evaluate_nif(op, node2, node3, cost_eval)
      assert delta == -907

      # Apply the move
      :ok = Native.relocate_with_depot_apply_nif(op, node2, node3)
      Native.search_route_update_nif(route)

      # There should now be an additional reload depot and trip
      assert Native.search_route_num_depots_nif(route) == 3
      assert Native.search_route_num_trips_nif(route) == 2
      assert Native.search_route_excess_load_nif(route) == [0]
    end

    test "inserts depot across routes - test_inserts_depot_across_routes" do
      # Tests that RelocateWithDepot inserts a reload depot along with the node
      # relocation across routes.
      {:ok, problem_data} = ok_small_multiple_trips()

      route1 = Native.make_search_route_nif(problem_data, [3], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [1, 2, 4], 1, 0)

      assert Native.search_route_num_clients_nif(route1) == 1
      assert Native.search_route_num_clients_nif(route2) == 3

      op = Native.create_relocate_with_depot_nif(problem_data)

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [500.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      node3 = Native.search_route_get_node_nif(route1, 1)
      node1 = Native.search_route_get_node_nif(route2, 1)

      # The proposal evaluates 1 | 3 2 4 and 1 3 | 2 4. PyVRP expects delta = -3052
      delta = Native.relocate_with_depot_evaluate_nif(op, node3, node1, cost_eval)
      assert delta == -3052

      :ok = Native.relocate_with_depot_apply_nif(op, node3, node1)
      Native.search_route_update_nif(route1)
      Native.search_route_update_nif(route2)

      # Route1 should now be empty
      assert Native.search_route_num_clients_nif(route1) == 0
    end
  end

  describe "RelocateWithDepot depot placement (PyVRP parity)" do
    test "reload depot before or after relocate - high load penalty" do
      # Based on test_reload_depot_before_or_after_relocate
      # With large load penalty, depot inserted after client 1
      {:ok, problem_data} = ok_small_multiple_trips()

      route = Native.make_search_route_nif(problem_data, [1, 2, 3, 4], 0, 0)

      op = Native.create_relocate_with_depot_nif(problem_data)

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [1000.0],
          tw_penalty: 1.0,
          dist_penalty: 0.0
        )

      node1 = Native.search_route_get_node_nif(route, 1)
      node2 = Native.search_route_get_node_nif(route, 2)

      # PyVRP expects delta = -3897 with load_penalty=1000
      delta = Native.relocate_with_depot_evaluate_nif(op, node1, node2, cost_eval)
      assert delta == -3897
    end

    test "reload depot before or after relocate - moderate load penalty" do
      # With moderate load penalty, depot inserted before client 1
      {:ok, problem_data} = ok_small_multiple_trips()

      route = Native.make_search_route_nif(problem_data, [1, 2, 3, 4], 0, 0)

      op = Native.create_relocate_with_depot_nif(problem_data)

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [300.0],
          tw_penalty: 1.0,
          dist_penalty: 0.0
        )

      node1 = Native.search_route_get_node_nif(route, 1)
      node2 = Native.search_route_get_node_nif(route, 2)

      # PyVRP expects delta = -54 with load_penalty=300
      delta = Native.relocate_with_depot_evaluate_nif(op, node1, node2, cost_eval)
      assert delta == -54
    end
  end

  describe "RelocateWithDepot best depot selection (PyVRP parity)" do
    test "inserts best reload depot not just first improving" do
      # Based on test_inserts_best_reload_depot
      # Tests that RelocateWithDepot inserts the best possible reload depot
      mat = [
        [0, 0, 100, 100],
        [0, 0, 0, 0],
        [100, 0, 0, 0],
        [100, 0, 0, 0]
      ]

      model =
        Model.new()
        # depot 0 - expensive
        |> Model.add_depot(x: 0, y: 0)
        # depot 1 - free
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 0, y: 0, delivery: [5])
        |> Model.add_client(x: 0, y: 0, delivery: [5])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [5],
          reload_depots: [0, 1]
        )
        |> Model.set_distance_matrices([mat])
        |> Model.set_duration_matrices([mat])

      {:ok, problem_data} = Model.to_problem_data(model)

      route = Native.make_search_route_nif(problem_data, [2, 3], 0, 0)

      assert Native.search_route_has_excess_load_nif(route) == true
      assert Native.search_route_excess_load_nif(route) == [5]

      op = Native.create_relocate_with_depot_nif(problem_data)

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [500.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      node2 = Native.search_route_get_node_nif(route, 1)
      node3 = Native.search_route_get_node_nif(route, 2)

      # Should use depot 1 (free) not depot 0 (expensive). PyVRP expects -2500
      delta = Native.relocate_with_depot_evaluate_nif(op, node2, node3, cost_eval)
      assert delta == -2500

      :ok = Native.relocate_with_depot_apply_nif(op, node2, node3)
      Native.search_route_update_nif(route)

      assert Native.search_route_has_excess_load_nif(route) == false
    end
  end

  describe "RelocateWithDepot fixed vehicle cost (PyVRP parity)" do
    test "accounts for fixed vehicle cost when route becomes empty" do
      # Based on test_fixed_vehicle_cost
      mat = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 0, y: 0, delivery: [5])
        |> Model.add_client(x: 0, y: 0, delivery: [4])
        |> Model.add_vehicle_type(
          num_available: 2,
          capacity: [4],
          fixed_cost: 2000,
          reload_depots: [0],
          max_reloads: 1
        )
        |> Model.set_distance_matrices([mat])
        |> Model.set_duration_matrices([mat])

      {:ok, problem_data} = Model.to_problem_data(model)

      route1 = Native.make_search_route_nif(problem_data, [1], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [2], 1, 0)

      op = Native.create_relocate_with_depot_nif(problem_data)

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [0.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      node1 = Native.search_route_get_node_nif(route1, 1)
      node2 = Native.search_route_get_node_nif(route2, 1)

      # After this move, route1 is empty -> saves fixed cost of -2000
      delta = Native.relocate_with_depot_evaluate_nif(op, node1, node2, cost_eval)
      assert delta == -2000
    end
  end

  describe "RelocateWithDepot max trips constraint (PyVRP parity)" do
    test "does not evaluate if already max trips" do
      # Based on test_does_not_evaluate_if_already_max_trips
      {:ok, problem_data} = ok_small_multiple_trips()

      # Route with reload depot already: [3, 0, 1, 2, 4]
      # This means: start -> 3 -> reload -> 1 -> 2 -> 4 -> end = 2 trips
      route = Native.make_search_route_nif(problem_data, [3, 0, 1, 2, 4], 0, 0)

      assert Native.search_route_num_trips_nif(route) == 2

      op = Native.create_relocate_with_depot_nif(problem_data)

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [10_000.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      # Try to add another depot - should return 0 since max trips reached
      # node after reload
      node3 = Native.search_route_get_node_nif(route, 3)
      node4 = Native.search_route_get_node_nif(route, 4)

      delta = Native.relocate_with_depot_evaluate_nif(op, node3, node4, cost_eval)
      # Cannot add another trip, so delta should be 0
      assert delta == 0
      assert Native.search_route_num_trips_nif(route) == Native.search_route_max_trips_nif(route)
    end
  end

  describe "RelocateWithDepot depot insertion positions (PyVRP parity)" do
    test "can insert reload after start depot" do
      # Based on test_can_insert_reload_after_start_depot
      mat = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 0, y: 0, delivery: [1])
        |> Model.add_client(x: 0, y: 0, delivery: [1])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [5],
          initial_load: [5],
          reload_depots: [0]
        )
        |> Model.set_distance_matrices([mat])
        |> Model.set_duration_matrices([mat])

      {:ok, problem_data} = Model.to_problem_data(model)

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)

      op = Native.create_relocate_with_depot_nif(problem_data)

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [1.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      # Evaluate turning "1 2" into "| 2 1" which resolves initial load
      node2 = Native.search_route_get_node_nif(route, 2)
      depot = Native.search_route_get_node_nif(route, 0)

      delta = Native.relocate_with_depot_evaluate_nif(op, node2, depot, cost_eval)
      # PyVRP expects -2
      assert delta == -2
    end

    test "can insert reload before end depot" do
      # Based on test_can_insert_reload_before_end_depot
      mat = [
        [0, 0, 10, 10],
        [0, 0, 0, 0],
        [10, 0, 0, 0],
        [10, 0, 0, 0]
      ]

      model =
        Model.new()
        # depot 0
        |> Model.add_depot(x: 0, y: 0)
        # depot 1
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 0, y: 0, delivery: [0])
        |> Model.add_client(x: 0, y: 0, delivery: [0])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [10],
          reload_depots: [0, 1]
        )
        |> Model.set_distance_matrices([mat])
        |> Model.set_duration_matrices([Enum.map(mat, fn row -> Enum.map(row, fn _ -> 0 end) end)])

      {:ok, problem_data} = Model.to_problem_data(model)

      route = Native.make_search_route_nif(problem_data, [2, 3], 0, 0)

      op = Native.create_relocate_with_depot_nif(problem_data)

      {:ok, cost_eval} =
        Native.create_cost_evaluator(
          load_penalties: [0.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      node2 = Native.search_route_get_node_nif(route, 1)
      node3 = Native.search_route_get_node_nif(route, 2)

      # Should insert depot 1 (free) at end. PyVRP expects -10
      delta = Native.relocate_with_depot_evaluate_nif(op, node2, node3, cost_eval)
      assert delta == -10
    end
  end

  describe "RelocateWithDepot supports (PyVRP parity)" do
    test "returns false for instances without reload depots" do
      # ok_small has no reload depots
      {:ok, problem_data} = ok_small()
      refute Native.relocate_with_depot_supports_nif(problem_data)
    end

    test "returns true for instances with reload depots" do
      # ok_small_multiple_trips has reload depots
      {:ok, problem_data} = ok_small_multiple_trips()
      assert Native.relocate_with_depot_supports_nif(problem_data)
    end
  end

  # Helper function to create OkSmall instance (no reload depots)
  defp ok_small do
    # Same as ok_small_multiple_trips but without reload_depots and max_reloads
    distances = [
      [0, 1544, 1944, 1931, 1476],
      [1726, 0, 1992, 1427, 1593],
      [1965, 1975, 0, 621, 1090],
      [2063, 1433, 647, 0, 818],
      [1475, 1594, 1090, 828, 0]
    ]

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
        tw_late: 45_000
      )
      |> Model.set_distance_matrices([distances])
      |> Model.set_duration_matrices([distances])

    Model.to_problem_data(model)
  end

  # Helper function to create OkSmall multiple trips instance
  defp ok_small_multiple_trips do
    # Depot at (2334, 726)
    # Clients at (226, 1297), (590, 530), (435, 718), (1191, 639)
    # Demands: [5, 5, 3, 5], Capacity: 10
    # With reload_depots: [0], max_reloads: 1

    distances = [
      [0, 1544, 1944, 1931, 1476],
      [1726, 0, 1992, 1427, 1593],
      [1965, 1975, 0, 621, 1090],
      [2063, 1433, 647, 0, 818],
      [1475, 1594, 1090, 828, 0]
    ]

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
end

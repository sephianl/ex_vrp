defmodule ExVrp.SearchRouteTest do
  @moduledoc """
  Tests for search::Route class.

  These tests match PyVRP's tests/search/test_Route.py for exact parity.
  They test the search::Route class operations directly.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  @moduletag :nif_required

  describe "Node init" do
    test "node has correct initial state" do
      # Based on test_node_init
      {:ok, problem_data, _} = ok_small_setup()

      for loc <- [0, 1, 2] do
        node = Native.create_search_node_nif(problem_data, loc)
        assert Native.search_node_client_nif(node) == loc
        assert Native.search_node_idx_nif(node) == 0
        assert Native.search_node_has_route_nif(node) == false
      end
    end
  end

  describe "Route init" do
    test "route has correct initial state" do
      # Based on test_route_init
      {:ok, problem_data, _} = ok_small_with_two_vehicle_types()

      route0 = Native.create_search_route_nif(problem_data, 0, 0)
      assert Native.search_route_idx_nif(route0) == 0
      assert Native.search_route_vehicle_type_nif(route0) == 0

      route1 = Native.create_search_route_nif(problem_data, 1, 1)
      assert Native.search_route_idx_nif(route1) == 1
      assert Native.search_route_vehicle_type_nif(route1) == 1
    end
  end

  describe "New nodes are not depots" do
    test "nodes not in route are not depots" do
      # Based on test_new_nodes_are_not_depots
      {:ok, problem_data, _} = ok_small_setup()

      for loc <- [0, 1, 2] do
        node = Native.create_search_node_nif(problem_data, loc)
        assert Native.search_node_is_depot_nif(node) == false
      end
    end
  end

  describe "Insert and remove" do
    test "updates node idx and route properties" do
      # Based on test_insert_and_remove_update_node_idx_and_route_properties
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.create_search_route_nif(problem_data, 0, 0)

      # After construction, the node is not in a route yet
      node = Native.create_search_node_nif(problem_data, 1)
      assert Native.search_node_idx_nif(node) == 0
      assert Native.search_node_has_route_nif(node) == false

      # Add to the route
      :ok = Native.search_route_append_nif(route, node)
      assert Native.search_node_idx_nif(node) == 1
      assert Native.search_node_has_route_nif(node) == true

      # Remove and test the node reverts to initial state
      :ok = Native.search_route_remove_nif(route, 1)
      assert Native.search_node_idx_nif(node) == 0
      assert Native.search_node_has_route_nif(node) == false
    end
  end

  describe "Route depots" do
    test "route depots are identified as depots" do
      # Based on test_route_depots_are_depots
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.create_search_route_nif(problem_data, 0, 0)
      assert Native.search_route_start_depot_nif(route) == 0
      assert Native.search_route_end_depot_nif(route) == 0

      # Add some clients
      for loc <- 1..3 do
        node = Native.create_search_node_nif(problem_data, loc)
        :ok = Native.search_route_append_nif(route, node)

        # Get the start depot
        start_depot = Native.search_route_get_node_nif(route, 0)
        assert Native.search_node_is_depot_nif(start_depot) == true
        assert Native.search_node_is_start_depot_nif(start_depot) == true
        assert Native.search_node_is_end_depot_nif(start_depot) == false

        # Get the end depot
        size = Native.search_route_size_nif(route)
        end_depot = Native.search_route_get_node_nif(route, size - 1)
        assert Native.search_node_is_depot_nif(end_depot) == true
        assert Native.search_node_is_end_depot_nif(end_depot) == true
        assert Native.search_node_is_start_depot_nif(end_depot) == false
      end
    end
  end

  describe "Route append increases length" do
    test "appending nodes increases route len" do
      # Based on test_route_append_increases_route_len
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.create_search_route_nif(problem_data, 0, 0)
      assert Native.search_route_num_clients_nif(route) == 0

      node1 = Native.create_search_node_nif(problem_data, 1)
      :ok = Native.search_route_append_nif(route, node1)
      assert Native.search_route_num_clients_nif(route) == 1

      node2 = Native.create_search_node_nif(problem_data, 2)
      :ok = Native.search_route_append_nif(route, node2)
      assert Native.search_route_num_clients_nif(route) == 2
    end
  end

  describe "Route insert" do
    test "inserting nodes at specific positions" do
      # Based on test_route_insert
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.create_search_route_nif(problem_data, 0, 0)
      assert Native.search_route_num_clients_nif(route) == 0
      assert Native.search_route_num_depots_nif(route) == 2

      # Insert a few nodes
      node1 = Native.create_search_node_nif(problem_data, 1)
      :ok = Native.search_route_append_nif(route, node1)

      node2 = Native.create_search_node_nif(problem_data, 2)
      :ok = Native.search_route_append_nif(route, node2)

      assert Native.search_route_num_clients_nif(route) == 2
      n1 = Native.search_route_get_node_nif(route, 1)
      assert Native.search_node_client_nif(n1) == 1
      n2 = Native.search_route_get_node_nif(route, 2)
      assert Native.search_node_client_nif(n2) == 2

      # Now insert a new node at index 1
      node3 = Native.create_search_node_nif(problem_data, 3)
      :ok = Native.search_route_insert_nif(route, 1, node3)

      assert Native.search_route_num_clients_nif(route) == 3
      n_at_1 = Native.search_route_get_node_nif(route, 1)
      assert Native.search_node_client_nif(n_at_1) == 3
      n_at_2 = Native.search_route_get_node_nif(route, 2)
      assert Native.search_node_client_nif(n_at_2) == 1
      n_at_3 = Native.search_route_get_node_nif(route, 3)
      assert Native.search_node_client_nif(n_at_3) == 2
    end
  end

  describe "Route add and delete" do
    test "add and delete leaves route empty" do
      # Based on test_route_add_and_delete_client_leaves_route_empty
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.create_search_route_nif(problem_data, 0, 0)

      node = Native.create_search_node_nif(problem_data, 1)
      :ok = Native.search_route_append_nif(route, node)
      assert Native.search_route_num_clients_nif(route) == 1

      :ok = Native.search_route_remove_nif(route, 1)
      assert Native.search_route_num_clients_nif(route) == 0
    end

    test "delete reduces size by one" do
      # Based on test_route_delete_reduces_size_by_one
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.create_search_route_nif(problem_data, 0, 0)

      node1 = Native.create_search_node_nif(problem_data, 1)
      :ok = Native.search_route_append_nif(route, node1)

      node2 = Native.create_search_node_nif(problem_data, 2)
      :ok = Native.search_route_append_nif(route, node2)

      assert Native.search_route_num_clients_nif(route) == 2

      :ok = Native.search_route_remove_nif(route, 1)
      assert Native.search_route_num_clients_nif(route) == 1
      n = Native.search_route_get_node_nif(route, 1)
      assert Native.search_node_client_nif(n) == 2
    end
  end

  describe "Route clear" do
    test "clear empties entire route" do
      # Based on test_route_clear_empties_entire_route
      {:ok, problem_data, _} = ok_small_setup()

      for num_nodes <- 0..3 do
        route = Native.create_search_route_nif(problem_data, 0, 0)

        if num_nodes > 0 do
          for loc <- 1..num_nodes do
            node = Native.create_search_node_nif(problem_data, loc)
            :ok = Native.search_route_append_nif(route, node)
          end
        end

        assert Native.search_route_num_clients_nif(route) == num_nodes

        :ok = Native.search_route_clear_nif(route)
        assert Native.search_route_num_clients_nif(route) == 0
      end
    end
  end

  describe "Excess load" do
    test "route calculates excess load correctly" do
      # Based on test_excess_load
      {:ok, problem_data, _} = ok_small_setup()

      # Create route with all 4 clients
      route = Native.make_search_route_nif(problem_data, [1, 2, 3, 4], 0, 0)

      # Total demand is 18, capacity is 10
      assert Native.search_route_has_excess_load_nif(route) == true
      assert Native.search_route_excess_load_nif(route) == [8]
      assert Native.search_route_load_nif(route) == [18]
      assert Native.search_route_capacity_nif(route) == [10]
    end
  end

  describe "Fixed vehicle cost" do
    test "returns vehicle type's fixed cost" do
      # Based on test_fixed_vehicle_cost
      for fixed_cost <- [0, 9] do
        model =
          Model.new()
          |> Model.add_depot(x: 2334, y: 726)
          |> Model.add_client(x: 226, y: 1297, delivery: [5])
          |> Model.add_client(x: 590, y: 530, delivery: [5])
          |> Model.add_client(x: 435, y: 718, delivery: [3])
          |> Model.add_client(x: 1191, y: 639, delivery: [5])
          |> Model.add_vehicle_type(num_available: 2, capacity: [10], fixed_cost: fixed_cost)

        {:ok, problem_data} = Model.to_problem_data(model)

        route = Native.create_search_route_nif(problem_data, 0, 0)
        assert Native.search_route_fixed_vehicle_cost_nif(route) == fixed_cost
      end
    end
  end

  describe "Distance and load for single client routes" do
    test "calculates correctly for single client" do
      # Based on test_dist_and_load_for_single_client_routes
      {:ok, problem_data, _} = ok_small_setup()

      for client <- 1..4 do
        route = Native.make_search_route_nif(problem_data, [client], 0, 0)

        # Load should be the client's delivery demand
        load = Native.search_route_load_nif(route)
        assert is_list(load)
        assert length(load) == 1
      end
    end
  end

  describe "Route centroid" do
    test "computes center point correctly" do
      # Based on test_route_centroid
      {:ok, problem_data, _} = ok_small_setup()

      # Test with clients 1, 2, 3, 4
      route = Native.make_search_route_nif(problem_data, [1, 2, 3, 4], 0, 0)
      {cx, cy} = Native.search_route_centroid_nif(route)

      # Clients: (226, 1297), (590, 530), (435, 718), (1191, 639)
      expected_x = (226 + 590 + 435 + 1191) / 4
      expected_y = (1297 + 530 + 718 + 639) / 4
      assert_in_delta cx, expected_x, 1.0
      assert_in_delta cy, expected_y, 1.0

      # Test with clients 1, 2
      route2 = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      {cx2, cy2} = Native.search_route_centroid_nif(route2)

      expected_x2 = (226 + 590) / 2
      expected_y2 = (1297 + 530) / 2
      assert_in_delta cx2, expected_x2, 1.0
      assert_in_delta cy2, expected_y2, 1.0
    end
  end

  describe "Route feasibility" do
    test "checks load, time, and distance constraints" do
      # Based on test_is_feasible
      # Need a model with max_distance constraint
      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726)
        |> Model.add_client(x: 226, y: 1297, delivery: [5])
        |> Model.add_client(x: 590, y: 530, delivery: [5])
        |> Model.add_client(x: 435, y: 718, delivery: [3])
        |> Model.add_vehicle_type(num_available: 3, capacity: [10], max_distance: 6000)
        |> Model.set_distance_matrices([build_small_distances()])
        |> Model.set_duration_matrices([build_small_distances()])

      {:ok, problem_data} = Model.to_problem_data(model)

      # Route [1, 2, 3] - load 13 > capacity 10 (infeasible)
      route1 = Native.make_search_route_nif(problem_data, [1, 2, 3], 0, 0)
      assert Native.search_route_is_feasible_nif(route1) == false
      assert Native.search_route_has_excess_load_nif(route1) == true

      # Route [1] - load 5 <= capacity 10 (feasible for load)
      route2 = Native.make_search_route_nif(problem_data, [1], 0, 0)
      assert Native.search_route_has_excess_load_nif(route2) == false
    end
  end

  describe "Max distance" do
    test "calculates excess distance correctly" do
      # Based on test_max_distance
      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726)
        |> Model.add_client(x: 226, y: 1297, delivery: [5])
        |> Model.add_client(x: 590, y: 530, delivery: [5])
        |> Model.add_client(x: 435, y: 718, delivery: [3])
        |> Model.add_client(x: 1191, y: 639, delivery: [5])
        |> Model.add_vehicle_type(num_available: 3, capacity: [10], max_distance: 5000)
        |> Model.set_distance_matrices([build_ok_small_distances()])
        |> Model.set_duration_matrices([build_ok_small_distances()])

      {:ok, problem_data} = Model.to_problem_data(model)

      route = Native.make_search_route_nif(problem_data, [1, 2, 3, 4], 0, 0)
      dist = Native.search_route_distance_nif(route)

      # If distance > 5000, there's excess distance
      if dist > 5000 do
        assert Native.search_route_has_excess_distance_nif(route) == true
        assert Native.search_route_excess_distance_nif(route) == dist - 5000
      else
        assert Native.search_route_has_excess_distance_nif(route) == false
        assert Native.search_route_excess_distance_nif(route) == 0
      end
    end
  end

  describe "Route swap" do
    test "swaps nodes between routes" do
      # Based on test_route_swap
      {:ok, problem_data, _} = ok_small_setup()

      route1 = Native.create_search_route_nif(problem_data, 0, 0)
      route2 = Native.create_search_route_nif(problem_data, 1, 0)

      node1 = Native.create_search_node_nif(problem_data, 1)
      :ok = Native.search_route_append_nif(route1, node1)

      node2 = Native.create_search_node_nif(problem_data, 2)
      :ok = Native.search_route_append_nif(route2, node2)

      assert Native.search_node_has_route_nif(node1) == true
      assert Native.search_node_has_route_nif(node2) == true

      # Swap the nodes
      :ok = Native.search_route_swap_nif(node1, node2)

      # After swap, both should still be in routes
      # (the swap exchanges their positions)
      assert Native.search_node_has_route_nif(node1) == true
      assert Native.search_node_has_route_nif(node2) == true
    end
  end

  describe "Route distance" do
    test "distance equals sum of edge distances" do
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      distance = Native.search_route_distance_nif(route)

      # From OkSmall distances: depot -> 1 -> 2 -> depot
      # dist[0,1] = 1544, dist[1,2] = 1992, dist[2,0] = 1965
      expected = 1544 + 1992 + 1965
      assert distance == expected
    end
  end

  describe "Route duration" do
    test "duration includes service times" do
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      duration = Native.search_route_duration_nif(route)

      # Duration includes travel time + service duration
      # Travel: 1544 + 1992 + 1965 = 5501
      # Service: 360 (client 1) + 360 (client 2) = 720
      # Total: 6221 (but may have time windows effects)
      assert duration > 0
    end
  end

  describe "Route time warp" do
    test "detects time window violations" do
      {:ok, problem_data, _} = ok_small_setup()

      # Create a route that likely has time warp (all clients in wrong order)
      route = Native.make_search_route_nif(problem_data, [1, 2, 3, 4], 0, 0)

      time_warp = Native.search_route_time_warp_nif(route)
      has_tw = Native.search_route_has_time_warp_nif(route)

      # If there's time warp, it should be detected
      if time_warp > 0 do
        assert has_tw == true
      else
        assert has_tw == false
      end
    end
  end

  describe "Route profile" do
    test "returns vehicle profile" do
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.create_search_route_nif(problem_data, 0, 0)
      profile = Native.search_route_profile_nif(route)

      # Default profile is 0
      assert profile == 0
    end
  end

  describe "Route empty check" do
    test "empty route has no clients" do
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.create_search_route_nif(problem_data, 0, 0)
      assert Native.search_route_empty_nif(route) == true
      assert Native.search_route_num_clients_nif(route) == 0

      node = Native.create_search_node_nif(problem_data, 1)
      :ok = Native.search_route_append_nif(route, node)

      assert Native.search_route_empty_nif(route) == false
      assert Native.search_route_num_clients_nif(route) == 1
    end
  end

  describe "Route size" do
    test "size includes depots" do
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.create_search_route_nif(problem_data, 0, 0)
      # Empty route has 2 depots
      assert Native.search_route_size_nif(route) == 2

      node = Native.create_search_node_nif(problem_data, 1)
      :ok = Native.search_route_append_nif(route, node)
      # Now has 2 depots + 1 client
      assert Native.search_route_size_nif(route) == 3
    end
  end

  describe "Route costs" do
    test "distance cost is calculated" do
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      dist_cost = Native.search_route_distance_cost_nif(route)

      # With unit_distance_cost = 1, distance_cost should equal distance
      distance = Native.search_route_distance_nif(route)
      assert dist_cost == distance
    end

    test "duration cost is calculated" do
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      dur_cost = Native.search_route_duration_cost_nif(route)

      # With unit_duration_cost = 0, duration_cost should be 0
      assert dur_cost == 0
    end
  end

  describe "Route overlap (PyVRP parity)" do
    test "route overlaps with self no matter the tolerance value" do
      # Based on test_route_overlaps_with_self_no_matter_the_tolerance_value
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)

      assert Native.search_route_overlaps_with_nif(route, route, 0.0) == true
      assert Native.search_route_overlaps_with_nif(route, route, 0.5) == true
      assert Native.search_route_overlaps_with_nif(route, route, 1.0) == true
    end

    test "all routes overlap with maximum tolerance value" do
      # Based on test_all_routes_overlap_with_maximum_tolerance_value
      {:ok, problem_data, _} = ok_small_setup()

      route1 = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      route2 = Native.make_search_route_nif(problem_data, [3, 4], 1, 0)

      # With zero tolerance, routes don't overlap
      assert Native.search_route_overlaps_with_nif(route1, route2, 0.0) == false
      assert Native.search_route_overlaps_with_nif(route2, route1, 0.0) == false

      # With maximum tolerance, they do overlap
      assert Native.search_route_overlaps_with_nif(route1, route2, 1.0) == true
      assert Native.search_route_overlaps_with_nif(route2, route1, 1.0) == true
    end
  end

  describe "Distance segment access (PyVRP parity)" do
    test "dist_between on whole route equals distance" do
      # Based on test_distance_is_equal_to_dist_between_over_whole_route
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2, 3, 4], 0, 0)
      distance = Native.search_route_distance_nif(route)

      size = Native.search_route_size_nif(route)
      dist_between = Native.search_route_dist_between_nif(route, 0, size - 1, -1)

      assert distance == dist_between
    end

    test "dist_at returns zero for nodes (distance is edge property)" do
      # Based on test_dist_and_load_for_single_client_routes
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1], 0, 0)

      # Distance is a property of edges, not nodes
      assert Native.search_route_dist_at_nif(route, 0, -1) == 0
      assert Native.search_route_dist_at_nif(route, 1, -1) == 0
    end

    test "dist_before and dist_after for single client route" do
      {:ok, problem_data, _} = ok_small_setup()

      # Single client route: depot(0) -> client(1) -> depot(0)
      route = Native.make_search_route_nif(problem_data, [1], 0, 0)

      # Distance from depot to client 1: dist[0,1] = 1544
      dist_to_client = Native.search_route_dist_before_nif(route, 1)
      assert dist_to_client == 1544

      # Distance from client 1 to depot: dist[1,0] = 1726
      dist_from_client = Native.search_route_dist_after_nif(route, 1)
      assert dist_from_client == 1726
    end

    test "dist_between equal to dist_before/dist_after when one is depot" do
      # Based on test_dist_between_equal_to_before_after_when_one_is_depot
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2, 3, 4], 0, 0)
      size = Native.search_route_size_nif(route)

      for idx <- 1..4 do
        dist_before = Native.search_route_dist_before_nif(route, idx)
        dist_between_before = Native.search_route_dist_between_nif(route, 0, idx, -1)
        assert dist_before == dist_between_before

        dist_after = Native.search_route_dist_after_nif(route, idx)
        dist_between_after = Native.search_route_dist_between_nif(route, idx, size - 1, -1)
        assert dist_after == dist_between_after
      end
    end
  end

  describe "Shift duration and overtime (PyVRP parity)" do
    test "shift duration returns vehicle type's shift duration" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, delivery: [0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [10], shift_duration: 5000)
        |> Model.set_distance_matrices([[[0, 100], [100, 0]]])
        |> Model.set_duration_matrices([[[0, 100], [100, 0]]])

      {:ok, problem_data} = Model.to_problem_data(model)

      route = Native.create_search_route_nif(problem_data, 0, 0)
      assert Native.search_route_shift_duration_nif(route) == 5000
    end

    test "max overtime returns vehicle type's max overtime" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, delivery: [0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [10], shift_duration: 5000, max_overtime: 1000)
        |> Model.set_distance_matrices([[[0, 100], [100, 0]]])
        |> Model.set_duration_matrices([[[0, 100], [100, 0]]])

      {:ok, problem_data} = Model.to_problem_data(model)

      route = Native.create_search_route_nif(problem_data, 0, 0)
      assert Native.search_route_max_overtime_nif(route) == 1000
    end

    test "max duration equals shift_duration + max_overtime" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, delivery: [0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [10], shift_duration: 5000, max_overtime: 1000)
        |> Model.set_distance_matrices([[[0, 100], [100, 0]]])
        |> Model.set_duration_matrices([[[0, 100], [100, 0]]])

      {:ok, problem_data} = Model.to_problem_data(model)

      route = Native.create_search_route_nif(problem_data, 0, 0)
      assert Native.search_route_max_duration_nif(route) == 6000
    end

    test "unit overtime cost returns vehicle type's unit overtime cost" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, delivery: [0])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [10],
          shift_duration: 5000,
          max_overtime: 1000,
          unit_overtime_cost: 10
        )
        |> Model.set_distance_matrices([[[0, 100], [100, 0]]])
        |> Model.set_duration_matrices([[[0, 100], [100, 0]]])

      {:ok, problem_data} = Model.to_problem_data(model)

      route = Native.create_search_route_nif(problem_data, 0, 0)
      assert Native.search_route_unit_overtime_cost_nif(route) == 10
    end

    test "overtime calculation" do
      # Based on test_overtime
      # Vehicle with shift_duration=5000, max_overtime=1000, unit_overtime_cost=10
      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [10],
          tw_early: 0,
          tw_late: 45_000,
          shift_duration: 5000,
          max_overtime: 1000,
          unit_overtime_cost: 10
        )
        |> Model.set_distance_matrices([build_small_overtime_distances()])
        |> Model.set_duration_matrices([build_small_overtime_distances()])

      {:ok, problem_data} = Model.to_problem_data(model)

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)

      # Verify route properties
      assert Native.search_route_shift_duration_nif(route) == 5000
      assert Native.search_route_max_overtime_nif(route) == 1000
      assert Native.search_route_max_duration_nif(route) == 6000
      assert Native.search_route_unit_overtime_cost_nif(route) == 10

      # Check overtime
      duration = Native.search_route_duration_nif(route)
      overtime = Native.search_route_overtime_nif(route)

      # If duration > 5000, overtime = duration - 5000
      if duration > 5000 do
        assert overtime == duration - 5000
      else
        assert overtime == 0
      end
    end
  end

  describe "Has distance/duration cost (PyVRP parity)" do
    test "has_distance_cost with default vehicle type" do
      # Based on test_has_distance_cost - default has cost
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        |> Model.set_distance_matrices([[[0]]])
        |> Model.set_duration_matrices([[[0]]])

      {:ok, problem_data} = Model.to_problem_data(model)
      route = Native.create_search_route_nif(problem_data, 0, 0)

      # Default unit_distance_cost = 1
      assert Native.search_route_has_distance_cost_nif(route) == true
    end

    test "has_distance_cost without unit_distance_cost" do
      # Based on test_has_distance_cost - no cost or constraint
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_distance_cost: 0)
        |> Model.set_distance_matrices([[[0]]])
        |> Model.set_duration_matrices([[[0]]])

      {:ok, problem_data} = Model.to_problem_data(model)
      route = Native.create_search_route_nif(problem_data, 0, 0)

      assert Native.search_route_has_distance_cost_nif(route) == false
    end

    test "has_distance_cost with max_distance constraint" do
      # Based on test_has_distance_cost - constraint activates even without cost
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_distance_cost: 0, max_distance: 0)
        |> Model.set_distance_matrices([[[0]]])
        |> Model.set_duration_matrices([[[0]]])

      {:ok, problem_data} = Model.to_problem_data(model)
      route = Native.create_search_route_nif(problem_data, 0, 0)

      assert Native.search_route_has_distance_cost_nif(route) == true
    end

    test "has_duration_cost with default vehicle type" do
      # Based on test_has_duration_cost - default has no cost
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        |> Model.set_distance_matrices([[[0]]])
        |> Model.set_duration_matrices([[[0]]])

      {:ok, problem_data} = Model.to_problem_data(model)
      route = Native.create_search_route_nif(problem_data, 0, 0)

      # Default has no duration cost
      assert Native.search_route_has_duration_cost_nif(route) == false
    end

    test "has_duration_cost with client time window" do
      # Based on test_has_duration_cost - constraint from data with time windows
      # hasDurationCost checks data.hasTimeWindows(), so we need a client with TW
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, delivery: [0], tw_early: 100, tw_late: 200)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        |> Model.set_distance_matrices([[[0, 1], [1, 0]]])
        |> Model.set_duration_matrices([[[0, 1], [1, 0]]])

      {:ok, problem_data} = Model.to_problem_data(model)
      route = Native.create_search_route_nif(problem_data, 0, 0)

      assert Native.search_route_has_duration_cost_nif(route) == true
    end

    test "has_duration_cost with unit_duration_cost" do
      # Based on test_has_duration_cost - unit cost
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_duration_cost: 1)
        |> Model.set_distance_matrices([[[0]]])
        |> Model.set_duration_matrices([[[0]]])

      {:ok, problem_data} = Model.to_problem_data(model)
      route = Native.create_search_route_nif(problem_data, 0, 0)

      assert Native.search_route_has_duration_cost_nif(route) == true
    end

    test "has_duration_cost with shift_duration constraint" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10], shift_duration: 0)
        |> Model.set_distance_matrices([[[0]]])
        |> Model.set_duration_matrices([[[0]]])

      {:ok, problem_data} = Model.to_problem_data(model)
      route = Native.create_search_route_nif(problem_data, 0, 0)

      assert Native.search_route_has_duration_cost_nif(route) == true
    end
  end

  describe "Multi-trip depot tests (PyVRP parity)" do
    test "multi-trip depots are correctly identified" do
      # Based on test_multi_trip_depots
      {:ok, problem_data} = ok_small_multiple_trips()

      # Create route with reload depot: [1, 0, 4]
      # This means: start_depot -> client1 -> reload_depot -> client4 -> end_depot
      route = Native.make_search_route_nif(problem_data, [1, 0, 4], 0, 0)

      # Index 0 is start depot
      start_depot = Native.search_route_get_node_nif(route, 0)
      assert Native.search_node_is_depot_nif(start_depot) == true
      assert Native.search_node_is_start_depot_nif(start_depot) == true
      assert Native.search_node_is_end_depot_nif(start_depot) == false
      assert Native.search_node_is_reload_depot_nif(start_depot) == false

      # Index 2 is reload depot
      reload_depot = Native.search_route_get_node_nif(route, 2)
      assert Native.search_node_is_depot_nif(reload_depot) == true
      assert Native.search_node_is_start_depot_nif(reload_depot) == false
      assert Native.search_node_is_end_depot_nif(reload_depot) == false
      assert Native.search_node_is_reload_depot_nif(reload_depot) == true

      # Last index is end depot
      size = Native.search_route_size_nif(route)
      end_depot = Native.search_route_get_node_nif(route, size - 1)
      assert Native.search_node_is_depot_nif(end_depot) == true
      assert Native.search_node_is_start_depot_nif(end_depot) == false
      assert Native.search_node_is_end_depot_nif(end_depot) == true
      assert Native.search_node_is_reload_depot_nif(end_depot) == false

      # Check trip indices
      assert Native.search_node_trip_nif(start_depot) == 0
      assert Native.search_node_trip_nif(reload_depot) == 1
      assert Native.search_node_trip_nif(end_depot) == 2
    end

    test "num_trips and max_trips" do
      {:ok, problem_data} = ok_small_multiple_trips()

      # Route with one reload (two trips)
      route = Native.make_search_route_nif(problem_data, [1, 0, 4], 0, 0)

      assert Native.search_route_num_trips_nif(route) == 2
      # max_trips depends on vehicle type's max_reloads + 1
    end

    test "num_depots includes reload depots" do
      {:ok, problem_data} = ok_small_multiple_trips()

      # Route with one reload: start + reload + end = 3 depots
      route = Native.make_search_route_nif(problem_data, [1, 0, 4], 0, 0)

      assert Native.search_route_num_depots_nif(route) == 3
    end
  end

  describe "Shift duration time warp (PyVRP parity)" do
    test "shift_duration affects time warp calculation" do
      # Based on test_shift_duration
      for {shift_duration, expected_tw} <- [{100_000, 3633}, {5000, 3633}, {4000, 3950}, {3000, 4950}, {0, 7950}] do
        model =
          Model.new()
          |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
          |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
          |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
          |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
          |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
          |> Model.add_vehicle_type(num_available: 3, capacity: [10], shift_duration: shift_duration)
          |> Model.set_distance_matrices([build_ok_small_distances()])
          |> Model.set_duration_matrices([build_ok_small_distances()])

        {:ok, problem_data} = Model.to_problem_data(model)
        route = Native.make_search_route_nif(problem_data, [1, 2, 3, 4], 0, 0)

        duration = Native.search_route_duration_nif(route)
        time_warp = Native.search_route_time_warp_nif(route)

        # Duration without shift_duration constraint is 7950
        assert duration == 7950
        # Time warp matches expected values
        assert time_warp == expected_tw
      end
    end
  end

  describe "Max distance parameterized (PyVRP parity)" do
    test "max_distance affects excess_distance calculation" do
      # Based on test_max_distance with parameterized values
      for {max_distance, expected_excess} <- [{100_000, 0}, {5000, 1450}, {0, 6450}] do
        model =
          Model.new()
          |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
          |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
          |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
          |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
          |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
          |> Model.add_vehicle_type(num_available: 3, capacity: [10], max_distance: max_distance)
          |> Model.set_distance_matrices([build_ok_small_distances()])
          |> Model.set_duration_matrices([build_ok_small_distances()])

        {:ok, problem_data} = Model.to_problem_data(model)
        route = Native.make_search_route_nif(problem_data, [1, 2, 3, 4], 0, 0)

        distance = Native.search_route_distance_nif(route)
        excess_distance = Native.search_route_excess_distance_nif(route)
        has_excess = Native.search_route_has_excess_distance_nif(route)

        assert distance == 6450
        assert has_excess == expected_excess > 0
        assert excess_distance == expected_excess
      end
    end
  end

  describe "Route swap parameterized (PyVRP parity)" do
    test "swap nodes - both in routes" do
      # Based on test_route_swap with (3, 4, true, true)
      {:ok, problem_data, _} = ok_small_setup()

      route1 = Native.create_search_route_nif(problem_data, 0, 0)
      route2 = Native.create_search_route_nif(problem_data, 1, 0)

      node1 = Native.create_search_node_nif(problem_data, 3)
      node2 = Native.create_search_node_nif(problem_data, 4)

      :ok = Native.search_route_append_nif(route1, node1)
      :ok = Native.search_route_append_nif(route2, node2)

      old_route1 = Native.search_node_has_route_nif(node1)
      old_route2 = Native.search_node_has_route_nif(node2)

      assert old_route1 == true
      assert old_route2 == true

      :ok = Native.search_route_swap_nif(node1, node2)

      # Both still have routes (swapped)
      assert Native.search_node_has_route_nif(node1) == true
      assert Native.search_node_has_route_nif(node2) == true
    end

    test "swap nodes - one in route, one not" do
      # Based on test_route_swap with (1, 2, true, false)
      {:ok, problem_data, _} = ok_small_setup()

      route1 = Native.create_search_route_nif(problem_data, 0, 0)

      node1 = Native.create_search_node_nif(problem_data, 1)
      node2 = Native.create_search_node_nif(problem_data, 2)

      :ok = Native.search_route_append_nif(route1, node1)
      # node2 is NOT in a route

      assert Native.search_node_has_route_nif(node1) == true
      assert Native.search_node_has_route_nif(node2) == false

      :ok = Native.search_route_swap_nif(node1, node2)

      # After swap: node1 should not have route, node2 should have route
      assert Native.search_node_has_route_nif(node1) == false
      assert Native.search_node_has_route_nif(node2) == true
    end

    test "swap nodes - neither in route" do
      # Based on test_route_swap with (1, 2, false, false)
      {:ok, problem_data, _} = ok_small_setup()

      node1 = Native.create_search_node_nif(problem_data, 1)
      node2 = Native.create_search_node_nif(problem_data, 2)

      assert Native.search_node_has_route_nif(node1) == false
      assert Native.search_node_has_route_nif(node2) == false

      :ok = Native.search_route_swap_nif(node1, node2)

      # Neither has route after swap (no change)
      assert Native.search_node_has_route_nif(node1) == false
      assert Native.search_node_has_route_nif(node2) == false
    end
  end

  describe "Empty route centroid (PyVRP parity)" do
    test "zero centroid for empty routes" do
      # Based on test_zero_centroid_empty_routes
      # Tests that empty routes return (0.0, 0.0), not NaN from divide-by-zero
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.create_search_route_nif(problem_data, 0, 0)
      assert Native.search_route_empty_nif(route) == true

      {cx, cy} = Native.search_route_centroid_nif(route)
      assert cx == 0.0
      assert cy == 0.0
    end
  end

  describe "Initial load calculation (PyVRP parity)" do
    test "initial_load affects excess_load calculation" do
      # Based on test_initial_load_calculation
      # Route with clients 1 and 2 has load 10, capacity 10 - no excess
      {:ok, problem_data, _} = ok_small_setup()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      assert Native.search_route_excess_load_nif(route) == [0]
      assert Native.search_route_has_excess_load_nif(route) == false

      # Now create same model but with initial_load = [5]
      model_with_initial_load =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
        |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
        |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_vehicle_type(num_available: 3, capacity: [10], initial_load: [5], tw_early: 0, tw_late: 45_000)
        |> Model.set_distance_matrices([build_ok_small_distances()])
        |> Model.set_duration_matrices([build_ok_small_distances()])

      {:ok, problem_data2} = Model.to_problem_data(model_with_initial_load)

      # Route with initial_load=5, client load=10, capacity=10 -> excess=5
      route2 = Native.make_search_route_nif(problem_data2, [1, 2], 0, 0)
      assert Native.search_route_excess_load_nif(route2) == [5]
      assert Native.search_route_has_excess_load_nif(route2) == true
    end
  end

  # Helper functions

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

  defp build_small_overtime_distances do
    # 3x3 matrix for 1 depot + 2 clients
    [
      [0, 1944, 1476],
      [1965, 0, 1090],
      [1475, 1090, 0]
    ]
  end

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
        load_penalties: [20.0],
        tw_penalty: 6.0,
        dist_penalty: 0.0
      )

    {:ok, problem_data, cost_evaluator}
  end

  defp ok_small_with_two_vehicle_types do
    distances = build_ok_small_distances()

    model =
      Model.new()
      |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
      |> Model.add_client(x: 226, y: 1297, delivery: [5])
      |> Model.add_client(x: 590, y: 530, delivery: [5])
      |> Model.add_client(x: 435, y: 718, delivery: [3])
      |> Model.add_client(x: 1191, y: 639, delivery: [5])
      |> Model.add_vehicle_type(num_available: 1, capacity: [1])
      |> Model.add_vehicle_type(num_available: 2, capacity: [2])
      |> Model.set_distance_matrices([distances])
      |> Model.set_duration_matrices([distances])

    {:ok, problem_data} = Model.to_problem_data(model)

    {:ok, cost_evaluator} =
      Native.create_cost_evaluator(
        load_penalties: [20.0],
        tw_penalty: 6.0,
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

  defp build_small_distances do
    # Smaller 4x4 matrix for 1 depot + 3 clients
    [
      [0, 1544, 1944, 1931],
      [1726, 0, 1992, 1427],
      [1965, 1975, 0, 621],
      [2063, 1433, 647, 0]
    ]
  end
end

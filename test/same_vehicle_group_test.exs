defmodule ExVrp.SameVehicleGroupTest do
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.SameVehicleGroup
  alias ExVrp.Solution

  describe "SameVehicleGroup struct" do
    test "constructor initializes fields" do
      group = SameVehicleGroup.new(clients: [1, 2, 3], name: "test")

      assert group.clients == [1, 2, 3]
      assert group.name == "test"
    end

    test "empty constructor creates empty group" do
      group = SameVehicleGroup.new()

      assert group.clients == []
      assert group.name == ""
    end

    test "add_client adds clients" do
      group =
        SameVehicleGroup.new()
        |> SameVehicleGroup.add_client(1)
        |> SameVehicleGroup.add_client(2)

      assert group.clients == [1, 2]
    end

    test "add_client raises for duplicate" do
      group = SameVehicleGroup.new(clients: [1, 2])

      assert_raise ArgumentError, ~r/already in same-vehicle group/, fn ->
        SameVehicleGroup.add_client(group, 1)
      end
    end

    test "clear empties the group" do
      group = SameVehicleGroup.new(clients: [1, 2, 3])
      assert SameVehicleGroup.size(group) == 3

      cleared = SameVehicleGroup.clear(group)
      assert SameVehicleGroup.size(cleared) == 0
      assert cleared.clients == []
    end

    test "size returns correct count" do
      assert SameVehicleGroup.size(SameVehicleGroup.new()) == 0
      assert SameVehicleGroup.size(SameVehicleGroup.new(clients: [1, 2, 3])) == 3
    end

    test "empty? returns correct value" do
      assert SameVehicleGroup.empty?(SameVehicleGroup.new()) == true
      assert SameVehicleGroup.empty?(SameVehicleGroup.new(clients: [1])) == false
    end
  end

  describe "Model.add_same_vehicle_group/3" do
    test "adds same-vehicle group to model" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_client(x: 2, y: 2)
        |> Model.add_client(x: 3, y: 3)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      [c1, c2, _c3] = model.clients

      model = Model.add_same_vehicle_group(model, [c1, c2], name: "group1")

      assert length(model.same_vehicle_groups) == 1
      [group] = model.same_vehicle_groups
      assert group.name == "group1"
      # Clients are offset by num_depots (1)
      assert group.clients == [1, 2]
    end

    test "raises when client not in model" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      # Create a client not in the model
      fake_client = ExVrp.Client.new(x: 99, y: 99)

      assert_raise ArgumentError, ~r/Client not in model/, fn ->
        Model.add_same_vehicle_group(model, [fake_client])
      end
    end
  end

  describe "depot addition updates same-vehicle group indices" do
    test "adding depot shifts client indices in same-vehicle groups" do
      # Create model with depot and clients first
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_client(x: 2, y: 2)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      [c1, c2] = model.clients

      # Add same-vehicle group (clients will have indices 1 and 2)
      model = Model.add_same_vehicle_group(model, [c1, c2])
      [group_before] = model.same_vehicle_groups
      assert group_before.clients == [1, 2]

      # Add another depot - indices should shift by 1
      model = Model.add_depot(model, x: 5, y: 5)
      [group_after] = model.same_vehicle_groups
      assert group_after.clients == [2, 3]
    end
  end

  describe "validation" do
    test "validates empty same-vehicle groups" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      # Manually add empty group
      model = %{model | same_vehicle_groups: [SameVehicleGroup.new()]}

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &String.contains?(&1, "empty"))
    end

    test "validates invalid client indices in same-vehicle groups" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      # Manually add group with invalid client index
      bad_group = SameVehicleGroup.new(clients: [999])
      model = %{model | same_vehicle_groups: [bad_group]}

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &String.contains?(&1, "invalid client index"))
    end

    test "validates duplicate clients in same-vehicle groups" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      # Manually add group with duplicate client
      bad_group = SameVehicleGroup.new(clients: [1, 1])
      model = %{model | same_vehicle_groups: [bad_group]}

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &String.contains?(&1, "duplicate"))
    end
  end

  describe "solution feasibility with same-vehicle constraint" do
    test "feasible when same-group clients are on same route" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_client(x: 2, y: 2)
        |> Model.add_client(x: 3, y: 3)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      [c1, c2, _c3] = model.clients

      # Clients c1 and c2 must be on same vehicle
      model = Model.add_same_vehicle_group(model, [c1, c2])

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 100)

      # Check that solution is feasible
      # Note: The solver should respect the same-vehicle constraint
      assert Solution.feasible?(result.best)
    end

    test "partial visits are allowed" do
      # When only some clients from a same-vehicle group are visited,
      # those visited must be on the same route. Unvisited clients are OK.
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, required: false)
        |> Model.add_client(x: 2, y: 2, required: false)
        |> Model.add_client(x: 3, y: 3, required: false)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      [c1, c2, c3] = model.clients

      # All three must be on same vehicle IF visited
      model = Model.add_same_vehicle_group(model, [c1, c2, c3])

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 100)

      # Solution should be feasible
      assert Solution.feasible?(result.best)
    end

    test "group_feasible? returns true when constraint is satisfied" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_client(x: 2, y: 2)
        |> Model.add_client(x: 3, y: 3)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      [c1, c2, _c3] = model.clients
      model = Model.add_same_vehicle_group(model, [c1, c2])

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 100)

      assert Solution.group_feasible?(result.best)
    end
  end

  describe "same-vehicle group with multi-trip" do
    test "same-vehicle constraint allows clients across multiple trips of same vehicle" do
      # This test verifies that clients in a same-vehicle group can be served
      # by the same vehicle across different trips. The constraint requires
      # same VEHICLE, not same TRIP.
      #
      # Setup: 4 clients with high delivery demands that can't fit in one trip
      # but can be served by a single vehicle doing multiple trips.
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        # 4 clients each requiring 60 units - too much for one trip (capacity 100)
        # but achievable with multi-trip
        |> Model.add_client(x: 10, y: 0, delivery: [60])
        |> Model.add_client(x: 20, y: 0, delivery: [60])
        |> Model.add_client(x: 30, y: 0, delivery: [60])
        |> Model.add_client(x: 40, y: 0, delivery: [60])
        # Single vehicle with reload capability
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0],
          max_reloads: 3
        )

      [c1, c2, c3, c4] = model.clients

      # All 4 clients must be served by the same vehicle
      model = Model.add_same_vehicle_group(model, [c1, c2, c3, c4])

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 500)
      solution = result.best

      # Solution should be feasible - same-vehicle constraint is satisfied
      # because all clients are on the same route (same vehicle), even if
      # they're spread across multiple trips
      assert Solution.feasible?(solution)
      assert Solution.group_feasible?(solution)
      assert Solution.complete?(solution)

      # Verify we have one route with multiple trips
      assert Solution.num_routes(solution) == 1

      # The route should have multiple trips since single trip can't fit all
      num_trips = Solution.route_num_trips(solution, 0)
      assert num_trips >= 2, "Expected multiple trips, got #{num_trips}"
    end

    test "same-vehicle constraint fails when clients are on different vehicles" do
      # Setup a scenario where clients COULD be split across vehicles
      # if not for the same-vehicle constraint
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [30])
        |> Model.add_client(x: 20, y: 0, delivery: [30])
        |> Model.add_client(x: 30, y: 0, delivery: [30])
        # Two vehicles, each can handle 2 clients
        |> Model.add_vehicle_type(num_available: 2, capacity: [70])

      [c1, c2, c3] = model.clients

      # All clients must be on same vehicle
      model = Model.add_same_vehicle_group(model, [c1, c2, c3])

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 200)
      solution = result.best

      # Should be feasible - solver must put all on one vehicle
      assert Solution.group_feasible?(solution)

      # All clients should be on the same route
      routes = Solution.routes(solution)

      if length(routes) == 1 do
        # Good - all clients on one route
        assert true
      else
        # If multiple routes, verify group clients are together
        route_with_group_clients =
          Enum.find(routes, fn route ->
            visits = ExVrp.Route.visits(route)
            # Check if this route has any of clients 1, 2, 3
            Enum.any?([1, 2, 3], &(&1 in visits))
          end)

        if route_with_group_clients do
          visits = ExVrp.Route.visits(route_with_group_clients)
          # All group clients should be on this route
          assert 1 in visits
          assert 2 in visits
          assert 3 in visits
        end
      end
    end

    test "multiple same-vehicle groups with multi-trip" do
      # Two independent same-vehicle groups
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        # Group 1: clients at x=10, 20
        |> Model.add_client(x: 10, y: 0, delivery: [40])
        |> Model.add_client(x: 20, y: 0, delivery: [40])
        # Group 2: clients at x=100, 110
        |> Model.add_client(x: 100, y: 0, delivery: [40])
        |> Model.add_client(x: 110, y: 0, delivery: [40])
        |> Model.add_vehicle_type(
          num_available: 2,
          capacity: [100],
          reload_depots: [0],
          max_reloads: 2
        )

      [c1, c2, c3, c4] = model.clients

      # Group 1: clients 1 and 2 must be on same vehicle
      model = Model.add_same_vehicle_group(model, [c1, c2], name: "group1")
      # Group 2: clients 3 and 4 must be on same vehicle
      model = Model.add_same_vehicle_group(model, [c3, c4], name: "group2")

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 300)
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.group_feasible?(solution)
    end

    test "same-vehicle group with time windows forcing multi-trip" do
      # Use time windows to force clients into different trips
      # Client 1: early time window
      # Client 2: late time window
      # Both must be on same vehicle but different trips due to time
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        # Early client - must be served in first trip
        |> Model.add_client(x: 10, y: 0, delivery: [30], tw_early: 0, tw_late: 50)
        # Late client - must be served after returning to depot
        |> Model.add_client(x: 20, y: 0, delivery: [30], tw_early: 200, tw_late: 300)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0],
          max_reloads: 2,
          tw_early: 0,
          tw_late: 500
        )

      [c1, c2] = model.clients
      model = Model.add_same_vehicle_group(model, [c1, c2])

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 300)
      solution = result.best

      # Should be feasible - both clients on same vehicle (different trips OK)
      assert Solution.feasible?(solution)
      assert Solution.group_feasible?(solution)
      assert Solution.complete?(solution)

      # Should have one route (one vehicle)
      assert Solution.num_routes(solution) == 1
    end

    test "same-vehicle group with split vehicles (multiple vehicle types with same name)" do
      # This tests the scenario where a single physical vehicle is modeled as
      # multiple vehicle types with the same name but different time windows.
      # This models "equipment constraints" where certain clients require a
      # specific piece of equipment (e.g., a key) and only the vehicle with that
      # equipment can service them. With multiple shifts of the same vehicle,
      # the equipment can be split across routes.
      #
      # This test matches PyVRP's test_same_vehicle_group_spanning_multiple_shifts_with_capacity

      # Duration matrix (5x5): depot at index 0, clients at 1-4
      # All locations close to each other (1 time unit travel)
      duration_matrix = [
        [0, 1, 1, 1, 1],
        [1, 0, 1, 1, 1],
        [1, 1, 0, 1, 1],
        [1, 1, 1, 0, 1],
        [1, 1, 1, 1, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        # 4 clients with demand 1 each, but vehicle capacity is only 2.
        # All 4 clients must be on the same vehicle (same-vehicle group).
        # This is only possible with multiple routes/shifts of that vehicle.
        |> Model.add_client(x: 1, y: 0, delivery: [1], required: true)
        |> Model.add_client(x: 2, y: 0, delivery: [1], required: true)
        |> Model.add_client(x: 3, y: 0, delivery: [1], required: true)
        |> Model.add_client(x: 4, y: 0, delivery: [1], required: true)
        # Two shifts of the same vehicle (same name, capacity=2 each)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [2],
          tw_early: 0,
          tw_late: 500,
          name: "v0"
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [2],
          tw_early: 500,
          tw_late: 1000,
          name: "v0"
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      [c1, c2, c3, c4] = model.clients

      # All 4 clients must be on the same vehicle (v0)
      # They can be split across the two shifts but must be on routes with the
      # same vehicle name.
      model = Model.add_same_vehicle_group(model, [c1, c2, c3, c4])

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 1000)
      solution = result.best

      # Should be feasible and group feasible
      assert Solution.feasible?(solution), "Solution should be feasible"
      assert Solution.group_feasible?(solution), "Solution should be group feasible"
      assert Solution.complete?(solution), "Solution should visit all clients"

      # Should have 2 routes (one per shift of the same vehicle)
      assert Solution.num_routes(solution) == 2

      # Both routes should be using vehicle types with name "v0"
      routes = Solution.routes(solution)

      for route <- routes do
        vtype_idx = ExVrp.Route.vehicle_type(route)
        vtype = Enum.at(model.vehicle_types, vtype_idx)
        assert vtype.name == "v0"
      end

      # All 4 clients should be visited across the 2 routes
      all_visits =
        routes
        |> Enum.flat_map(&ExVrp.Route.visits/1)
        |> MapSet.new()

      assert MapSet.equal?(all_visits, MapSet.new([1, 2, 3, 4]))
    end

    test "without same-vehicle constraint, split vehicles can serve different clients" do
      # First verify that split vehicles work correctly WITHOUT the constraint
      duration_matrix = [
        [0, 1, 1, 1, 1],
        [1, 0, 1, 1, 1],
        [1, 1, 0, 1, 1],
        [1, 1, 1, 0, 1],
        [1, 1, 1, 1, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 1, y: 0, service_duration: 116, tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 2, y: 0, service_duration: 116, tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 3, y: 0, service_duration: 116, tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 4, y: 0, service_duration: 116, tw_early: 0, tw_late: 1000)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [1000],
          tw_early: 0,
          tw_late: 250,
          name: "v0"
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [1000],
          tw_early: 500,
          tw_late: 800,
          name: "v0"
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      # NO same-vehicle group constraint

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 1000)
      solution = result.best

      # Should be feasible
      assert Solution.feasible?(solution), "Solution should be feasible without constraint"
      assert Solution.complete?(solution), "Solution should visit all clients"

      # Should have 2 routes
      assert Solution.num_routes(solution) == 2
    end
  end
end

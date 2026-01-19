defmodule ExVrp.MultiTripTest do
  @moduledoc """
  Tests for multi-trip VRP support.

  Multi-trip VRP allows vehicles to return to reload depots mid-route
  to pick up additional cargo for subsequent deliveries.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Depot
  alias ExVrp.Model
  alias ExVrp.Route
  alias ExVrp.ScheduledVisit
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.VehicleType

  describe "VehicleType multi-trip fields" do
    test "creates vehicle type with reload_depots" do
      vt =
        VehicleType.new(
          num_available: 2,
          capacity: [100],
          reload_depots: [0, 1]
        )

      assert vt.reload_depots == [0, 1]
    end

    test "creates vehicle type with max_reloads" do
      vt =
        VehicleType.new(
          num_available: 2,
          capacity: [100],
          max_reloads: 3
        )

      assert vt.max_reloads == 3
    end

    test "creates vehicle type with initial_load" do
      vt =
        VehicleType.new(
          num_available: 2,
          capacity: [100],
          initial_load: [50]
        )

      assert vt.initial_load == [50]
    end

    test "has sensible multi-trip defaults" do
      vt = VehicleType.new(num_available: 1, capacity: [50])

      assert vt.reload_depots == []
      assert vt.max_reloads == :infinity
      assert vt.initial_load == []
    end

    test "creates vehicle type with all multi-trip fields" do
      vt =
        VehicleType.new(
          num_available: 3,
          capacity: [100, 50],
          reload_depots: [0],
          max_reloads: 2,
          initial_load: [20, 10]
        )

      assert vt.num_available == 3
      assert vt.capacity == [100, 50]
      assert vt.reload_depots == [0]
      assert vt.max_reloads == 2
      assert vt.initial_load == [20, 10]
    end

    test "creates vehicle type with overtime fields" do
      vt =
        VehicleType.new(
          num_available: 1,
          capacity: [100],
          shift_duration: 480,
          max_overtime: 60,
          unit_overtime_cost: 2
        )

      assert vt.shift_duration == 480
      assert vt.max_overtime == 60
      assert vt.unit_overtime_cost == 2
    end

    test "has sensible overtime defaults" do
      vt = VehicleType.new(num_available: 1, capacity: [50])

      assert vt.shift_duration == :infinity
      assert vt.max_overtime == 0
      assert vt.unit_overtime_cost == 0
    end
  end

  describe "multi-trip model solving" do
    test "model with reload_depots can be solved" do
      # Create a simple problem where a vehicle might need to reload
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [60])
        |> Model.add_client(x: 20, y: 0, delivery: [60])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0],
          max_reloads: 2
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))

      assert result.best
      assert Solution.complete?(result.best)
    end

    test "model without reload_depots still works" do
      # Ensure non-multi-trip problems still work
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [30])
        |> Model.add_client(x: 20, y: 0, delivery: [30])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))

      assert result.best
      assert Solution.feasible?(result.best)
      assert Solution.complete?(result.best)
    end
  end

  describe "in-place depot insertion" do
    test "vehicle makes 4 trips when capacity allows only 1 item per trip" do
      # Vehicle can only carry 1 item at a time, must make 4 trips for 4 clients
      # This tests the in-place depot insertion capability
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, service_duration: 50)
        |> Model.add_client(x: 10, y: 0, delivery: [100], service_duration: 10)
        |> Model.add_client(x: 20, y: 0, delivery: [100], service_duration: 10)
        |> Model.add_client(x: 30, y: 0, delivery: [100], service_duration: 10)
        |> Model.add_client(x: 40, y: 0, delivery: [100], service_duration: 10)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0],
          max_reloads: :infinity,
          tw_early: 0,
          tw_late: 2000
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(1000))

      assert result.best
      assert Solution.complete?(result.best)

      # Should have exactly one route
      routes = Solution.routes(result.best)
      assert length(routes) == 1

      [route] = routes

      # Should have 4 trips (one client per trip due to capacity)
      assert Route.num_trips(route) == 4,
             "Expected 4 trips, got #{Route.num_trips(route)}"
    end

    test "auto-insert depot when single client exceeds remaining capacity" do
      # This test specifically exercises the Solution::insert capacity check.
      # When inserting a client would exceed capacity, it should automatically
      # insert a reload depot before the client.
      #
      # Setup: Vehicle capacity 100, clients each need 60.
      # After inserting client 1 (60), trying to insert client 2 (60) would
      # exceed capacity (60 + 60 = 120 > 100), so a depot should be auto-inserted.
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, service_duration: 10)
        |> Model.add_client(x: 10, y: 0, delivery: [60], service_duration: 5)
        |> Model.add_client(x: 20, y: 0, delivery: [60], service_duration: 5)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0],
          max_reloads: 5,
          tw_early: 0,
          tw_late: 1000
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(500))

      assert result.best
      assert Solution.complete?(result.best)
      assert Solution.feasible?(result.best)

      routes = Solution.routes(result.best)
      assert length(routes) == 1

      [route] = routes
      # Should need 2 trips (one client per trip)
      assert Route.num_trips(route) == 2,
             "Expected 2 trips (one client per trip), got #{Route.num_trips(route)}"
    end

    test "auto-insert depot respects max_reloads limit" do
      # With max_reloads: 1, vehicle can make at most 2 trips.
      # With 3 clients each needing full capacity, only 2 can be served.
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [100])
        |> Model.add_client(x: 20, y: 0, delivery: [100])
        |> Model.add_client(x: 30, y: 0, delivery: [100])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0],
          max_reloads: 1,
          tw_early: 0,
          tw_late: 1000
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(500))

      assert result.best
      routes = Solution.routes(result.best)
      assert length(routes) == 1

      [route] = routes
      # Can make at most 2 trips (max_reloads: 1 means 1 reload = 2 trips)
      assert Route.num_trips(route) <= 2

      # Solution won't be complete since we can't serve all clients
      # but shouldn't crash
    end

    test "vehicle makes 2 trips when capacity allows 2 items per trip" do
      # Vehicle can carry 2 items, needs 2 trips for 4 clients
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, service_duration: 50)
        |> Model.add_client(x: 10, y: 0, delivery: [50], service_duration: 10)
        |> Model.add_client(x: 20, y: 0, delivery: [50], service_duration: 10)
        |> Model.add_client(x: 30, y: 0, delivery: [50], service_duration: 10)
        |> Model.add_client(x: 40, y: 0, delivery: [50], service_duration: 10)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0],
          max_reloads: :infinity,
          tw_early: 0,
          tw_late: 2000
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(1000))

      assert result.best
      assert Solution.complete?(result.best)

      routes = Solution.routes(result.best)
      assert length(routes) == 1

      [route] = routes

      # Should have 2 trips (two clients per trip)
      assert Route.num_trips(route) == 2,
             "Expected 2 trips, got #{Route.num_trips(route)}"
    end
  end

  describe "multiple vehicles with multi-trip" do
    test "two vehicles each make independent multi-trips" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [100])
        |> Model.add_client(x: 20, y: 0, delivery: [100])
        |> Model.add_client(x: -10, y: 0, delivery: [100])
        |> Model.add_client(x: -20, y: 0, delivery: [100])
        |> Model.add_vehicle_type(
          num_available: 2,
          capacity: [100],
          reload_depots: [0],
          max_reloads: :infinity,
          tw_early: 0,
          tw_late: 1000
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(1000))

      assert result.best
      assert Solution.complete?(result.best)

      routes = Solution.routes(result.best)
      # Each vehicle should handle 2 clients with 2 trips each
      total_trips = routes |> Enum.map(&Route.num_trips/1) |> Enum.sum()
      assert total_trips == 4
    end
  end

  describe "pickup loads with multi-trip" do
    test "pickup loads trigger multi-trip when capacity exceeded" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, pickup: [60])
        |> Model.add_client(x: 20, y: 0, pickup: [60])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0],
          max_reloads: 5,
          tw_early: 0,
          tw_late: 1000
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(500))

      assert result.best
      assert Solution.complete?(result.best)

      [route] = Solution.routes(result.best)
      assert Route.num_trips(route) == 2
    end
  end

  describe "mixed pickup and delivery with multi-trip" do
    test "mixed pickup and delivery - all clients should be visited with multi-trip" do
      # This tests the correct handling of mixed pickup/delivery loads.
      # Setup:
      # - Vehicle capacity: 1000
      # - Clients 0, 2: pickup of 600 each (collect from client)
      # - Clients 1, 3: delivery of 600 each (deliver to client)
      #
      # For deliveries: vehicle must START with items loaded
      # For pickups: vehicle collects items FROM clients
      #
      # With capacity 1000 and multi-trip enabled:
      # - Can deliver to client 1 (load 600, deliver, return)
      # - Can deliver to client 3 (load 600, deliver, return)
      # - Can pickup from client 0 (drive, pickup 600, return)
      # - Can pickup from client 2 (drive, pickup 600, return)
      #
      # All 4 clients should be served across multiple trips.
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, service_duration: 60)
        |> Model.add_client(x: 10, y: 0, pickup: [600], service_duration: 116)
        |> Model.add_client(x: 20, y: 0, delivery: [600], service_duration: 116)
        |> Model.add_client(x: 30, y: 0, pickup: [600], service_duration: 116)
        |> Model.add_client(x: 40, y: 0, delivery: [600], service_duration: 116)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [1000],
          reload_depots: [0],
          max_reloads: :infinity,
          tw_early: 0,
          tw_late: 10_000
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(1000))

      assert result.best

      # All 4 clients should be visited
      assert Solution.complete?(result.best),
             "Solution should be complete - all 4 clients should be visited"

      assert Solution.feasible?(result.best),
             "Solution should be feasible"

      routes = Solution.routes(result.best)
      assert length(routes) == 1

      [route] = routes

      # Should need at least 2 trips since we can't fit two 600 deliveries
      # or two 600 pickups in one trip
      assert Route.num_trips(route) >= 2,
             "Expected at least 2 trips, got #{Route.num_trips(route)}"
    end

    test "delivery clients require pre-loading - cannot fit two 600 deliveries in 1000 capacity" do
      # Two delivery-only clients, each needs 600 delivered.
      # Vehicle capacity is 1000.
      # Both require the vehicle to START with items loaded.
      # 600 + 600 = 1200 > 1000, so cannot do both in one trip.
      # Must do 2 trips.
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [600])
        |> Model.add_client(x: 20, y: 0, delivery: [600])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [1000],
          reload_depots: [0],
          max_reloads: :infinity,
          tw_early: 0,
          tw_late: 10_000
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(500))

      assert result.best
      assert Solution.complete?(result.best)
      assert Solution.feasible?(result.best)

      [route] = Solution.routes(result.best)
      assert Route.num_trips(route) == 2
    end

    test "zelo scenario - mixed weight and volume with optional clients" do
      # This exactly replicates the zelo test scenario that fails.
      # 4 clients, each with:
      # - Clients 0, 2: weight pickup of 600 + volume delivery of 250
      # - Clients 1, 3: weight delivery of 600 + volume delivery of 250
      #
      # Vehicle capacity: [1000, 1000, 1000] (weight, space, volume)
      #
      # All clients are optional (required=false) with a prize.
      #
      # The solver should be able to visit all 4 clients across multiple trips.
      #
      # Using the exact same asymmetric duration matrix as zelo test:
      # Location indices: 0-3 are clients, 4 is depot
      # ExVRP expects: [depot, clients...] so we need to remap
      # ExVRP indices: 0=depot, 1-4=clients

      # Original zelo matrix (rows/cols: 0=client0, 1=client1, 2=client2, 3=client3, 4=depot):
      # [
      #   [0, 4, 3, 2, 1],  # from client 0
      #   [4, 0, 4, 1, 1],  # from client 1
      #   [3, 4, 0, 4, 1],  # from client 2
      #   [2, 1, 4, 0, 1],  # from client 3
      #   [1, 2, 1, 1, 0]   # from depot
      # ]
      # Reorder to ExVRP format: [depot, client0, client1, client2, client3]
      duration_matrix = [
        # to: depot, c0, c1, c2, c3
        [0, 1, 2, 1, 1],
        # from depot
        [1, 0, 4, 3, 2],
        # from client 0
        [1, 4, 0, 4, 1],
        # from client 1
        [1, 3, 4, 0, 4],
        # from client 2
        [1, 2, 1, 4, 0]
        # from client 3
      ]

      # Distance matrix includes depot_reload_time (60) for trips TO depot
      # This affects cost optimization but not timing
      distance_matrix = [
        # to: depot, c0, c1, c2, c3
        [0, 1, 2, 1, 1],
        # from depot
        [61, 0, 4, 3, 2],
        # from client 0 (61 = 1 + 60 reload time)
        [61, 4, 0, 4, 1],
        # from client 1
        [61, 3, 4, 0, 4],
        # from client 2
        [61, 2, 1, 4, 0]
        # from client 3
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000, service_duration: 60)
        # Client 0: weight pickup + volume delivery
        |> Model.add_client(
          x: 0,
          y: 0,
          delivery: [0, 250, 250],
          pickup: [600, 0, 0],
          service_duration: 116,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        # Client 1: weight delivery + volume delivery
        |> Model.add_client(
          x: 1,
          y: 0,
          delivery: [600, 250, 250],
          pickup: [0, 0, 0],
          service_duration: 116,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        # Client 2: weight pickup + volume delivery
        |> Model.add_client(
          x: 2,
          y: 0,
          delivery: [0, 250, 250],
          pickup: [600, 0, 0],
          service_duration: 116,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        # Client 3: weight delivery + volume delivery
        |> Model.add_client(
          x: 3,
          y: 0,
          delivery: [600, 250, 250],
          pickup: [0, 0, 0],
          service_duration: 116,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [1000, 1000, 1000],
          reload_depots: [0],
          max_reloads: :infinity,
          tw_early: 0,
          tw_late: 86_400,
          shift_duration: 86_400,
          name: "v0"
        )
        |> Model.set_distance_matrices([distance_matrix, distance_matrix])
        |> Model.set_duration_matrices([duration_matrix, duration_matrix])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(10_000))

      assert result.best

      # All 4 clients should be visited (Solution.complete? checks this)
      assert Solution.complete?(result.best),
             "Solution should be complete - all 4 clients should be visited. " <>
               "Routes: #{inspect(Solution.routes(result.best))}"

      assert Solution.feasible?(result.best)
    end
  end

  describe "multiple load dimensions" do
    test "multi-trip triggered by second dimension exceeding capacity" do
      # First dimension (volume) has plenty of capacity, second (weight) is constrained
      # Vehicle: capacity [1000, 100], clients need [10, 60] each
      # First dimension: 10+10=20 << 1000, no problem
      # Second dimension: 60+60=120 > 100, triggers multi-trip
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10, 60], pickup: [0, 0])
        |> Model.add_client(x: 20, y: 0, delivery: [10, 60], pickup: [0, 0])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [1000, 100],
          reload_depots: [0],
          max_reloads: 5,
          tw_early: 0,
          tw_late: 1000
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(500))

      assert result.best
      assert Solution.complete?(result.best)

      [route] = Solution.routes(result.best)
      assert Route.num_trips(route) == 2
    end
  end

  describe "different reload depot" do
    test "uses specified reload depot different from start depot" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 50, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [100])
        |> Model.add_client(x: 20, y: 0, delivery: [100])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          start_depot: 0,
          end_depot: 0,
          reload_depots: [1],
          max_reloads: 5,
          tw_early: 0,
          tw_late: 2000
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(500))

      assert result.best
      assert Solution.complete?(result.best)

      [route] = Solution.routes(result.best)
      assert Route.num_trips(route) == 2
    end
  end

  describe "Depot service_duration" do
    test "creates depot with service_duration" do
      depot = Depot.new(x: 0, y: 0, service_duration: 30)

      assert depot.x == 0
      assert depot.y == 0
      assert depot.service_duration == 30
    end

    test "depot service_duration defaults to 0" do
      depot = Depot.new(x: 0, y: 0)

      assert depot.service_duration == 0
    end

    test "depot service_duration is applied at reload depots" do
      # Create a problem where the vehicle must reload mid-route
      # and verify the service duration is accounted for in timing
      #
      # Setup: depot at (0,0), clients at (10,0) and (20,0)
      # Vehicle capacity is 50, each client needs 40 delivery
      # So vehicle must return to depot to reload between clients
      #
      # With unit distance matrix (duration = distance):
      # - Trip 1: depot(0) -> client1(10) -> depot(0): 10 + 10 = 20 travel
      # - Reload at depot: 15 service time
      # - Trip 2: depot(0) -> client2(20) -> depot(0): 20 + 20 = 40 travel
      # Total travel: 60, plus service time at reload: 15 = 75

      depot_service_time = 15

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, service_duration: depot_service_time)
        |> Model.add_client(x: 10, y: 0, delivery: [40])
        |> Model.add_client(x: 20, y: 0, delivery: [40])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [50],
          reload_depots: [0],
          max_reloads: 1
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(500))

      assert result.best
      assert Solution.feasible?(result.best)

      # Check that there's exactly one route
      routes = Solution.routes(result.best)
      assert length(routes) == 1

      [route] = routes

      # Should have 2 trips (since capacity forces a reload)
      assert Route.num_trips(route) >= 2

      # Get the schedule and verify service time at reload depot
      schedule =
        route
        |> Route.schedule()
        |> Enum.map(&ScheduledVisit.from_tuple/1)

      # Find depot visits that have service time (reload depots)
      # The first depot visit (start) should have 0 service time
      # Intermediate depot visits (reloads) should have service_duration
      depot_visits_with_service =
        Enum.filter(schedule, fn visit ->
          visit.location == 0 and visit.trip > 0 and
            visit.start_service != visit.end_service
        end)

      # There should be at least one reload depot with service time
      if Route.num_trips(route) > 1 do
        refute Enum.empty?(depot_visits_with_service)

        # Each reload visit should have exactly depot_service_time duration
        for visit <- depot_visits_with_service do
          service_dur = visit.end_service - visit.start_service
          assert service_dur == depot_service_time
        end
      end
    end

    test "no service time at start depot for first trip" do
      # Verify that the start depot does NOT have service time added
      # Only reload depots should have service time

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, service_duration: 30)
        |> Model.add_client(x: 10, y: 0, delivery: [20])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100]
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))

      assert result.best
      routes = Solution.routes(result.best)
      assert length(routes) == 1

      [route] = routes

      schedule =
        route
        |> Route.schedule()
        |> Enum.map(&ScheduledVisit.from_tuple/1)

      # First scheduled visit should be the start depot with no service time
      [first_visit | _] = schedule
      assert first_visit.location == 0
      assert first_visit.trip == 0
      assert first_visit.start_service == first_visit.end_service
    end

    test "depot service_duration affects route duration" do
      # Create two identical problems, one with service_duration and one without
      # Verify the one with service_duration has longer route duration

      base_model =
        Model.new()
        |> Model.add_client(x: 10, y: 0, delivery: [40])
        |> Model.add_client(x: 20, y: 0, delivery: [40])

      model_no_service =
        base_model
        |> Model.add_depot(x: 0, y: 0, service_duration: 0)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [50],
          reload_depots: [0],
          max_reloads: 1
        )

      model_with_service =
        base_model
        |> Model.add_depot(x: 0, y: 0, service_duration: 100)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [50],
          reload_depots: [0],
          max_reloads: 1
        )

      {:ok, result_no} =
        Solver.solve(model_no_service, stop: ExVrp.StoppingCriteria.max_iterations(500))

      {:ok, result_with} =
        Solver.solve(model_with_service, stop: ExVrp.StoppingCriteria.max_iterations(500))

      assert result_no.best
      assert result_with.best

      # Get the route from each solution
      [route_no] = Solution.routes(result_no.best)
      [route_with] = Solution.routes(result_with.best)

      # If both solutions have the same structure (same number of trips),
      # the one with service time should have longer duration
      if Route.num_trips(route_no) == Route.num_trips(route_with) and
           Route.num_trips(route_no) > 1 do
        # Route with service time should have longer duration
        assert Route.duration(route_with) > Route.duration(route_no)

        # The difference should be approximately (num_reloads * service_time)
        num_reloads = Route.num_trips(route_with) - 1
        expected_difference = num_reloads * 100

        actual_difference = Route.duration(route_with) - Route.duration(route_no)
        assert actual_difference == expected_difference
      end
    end
  end
end

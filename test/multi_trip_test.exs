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

defmodule ExVrp.VehicleGroupTest do
  @moduledoc """
  Tests for vehicle group gap constraint.

  Vehicle groups represent vehicle types that belong to the same physical
  driver. The solver enforces a minimum time gap between consecutive routes
  assigned to vehicle types in the same group.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solution
  alias ExVrp.Solver

  describe "model validation" do
    test "model with valid vehicle group validates" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], tw_early: 0, tw_late: 500)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], tw_early: 600, tw_late: 1000)
        |> Model.add_vehicle_group(vehicle_types: [0, 1], min_gap: 100)

      assert :ok = Model.validate(model)
    end

    test "model with empty vehicle group fails validation" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_vehicle_group(vehicle_types: [], min_gap: 100)

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &String.contains?(&1, "empty"))
    end

    test "model with invalid vehicle type index fails validation" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_vehicle_group(vehicle_types: [0, 99], min_gap: 100)

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &String.contains?(&1, "invalid"))
    end
  end

  describe "solver with vehicle groups" do
    test "solver accepts model with vehicle group" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, service_duration: 50)
        |> Model.add_client(x: 10, y: 0, delivery: [50])
        |> Model.add_client(x: 20, y: 0, delivery: [50])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 0,
          tw_late: 500
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 600,
          tw_late: 1200
        )
        |> Model.add_vehicle_group(vehicle_types: [0, 1], min_gap: 100)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(200))

      assert result.best
      solution = result.best
      assert Solution.num_routes(solution) > 0
    end

    test "model without vehicle groups still works" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))

      assert result.best
      assert Solution.feasible?(result.best)
    end

    test "gap constraint prevents overlapping shifts from being scheduled too close" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        |> Model.add_client(
          x: 1,
          y: 0,
          tw_early: 0,
          tw_late: 1000,
          service_duration: 10,
          delivery: [50],
          required: false,
          prize: 100
        )
        |> Model.add_client(
          x: 1,
          y: 0,
          tw_early: 0,
          tw_late: 1000,
          service_duration: 10,
          delivery: [50],
          required: false,
          prize: 100
        )
        # Shift 1: 0-50
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 0,
          tw_late: 50
        )
        # Shift 2: 25-100 (only 25 units after shift 1 could end — less than min_gap)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 25,
          tw_late: 100
        )
        # Same driver, needs 100 units gap between shifts
        |> Model.add_vehicle_group(vehicle_types: [0, 1], min_gap: 100)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(1000))

      solution = result.best

      active_routes =
        Enum.count(0..(Solution.num_routes(solution) - 1), fn idx ->
          schedule = Solution.route_schedule(solution, idx)
          schedule != []
        end)

      assert active_routes <= 1,
             "Expected at most 1 active route due to gap constraint, got #{active_routes}"
    end

    test "negative min_gap fails validation" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_vehicle_group(vehicle_types: [0], min_gap: -10)

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &String.contains?(&1, "negative"))
    end
  end

  describe "gap enforcement in solution" do
    test "no adjustment when gap between shifts is sufficient" do
      # Shift 1: [0, 200], Shift 2: [500, 1000] — gap of ~300+ >> min_gap of 100
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        |> Model.add_client(
          x: 1,
          y: 0,
          tw_early: 0,
          tw_late: 200,
          service_duration: 10,
          delivery: [50],
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 1,
          y: 0,
          tw_early: 500,
          tw_late: 1000,
          service_duration: 10,
          delivery: [50],
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 0,
          tw_late: 200
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 500,
          tw_late: 1000
        )
        |> Model.add_vehicle_group(vehicle_types: [0, 1], min_gap: 100)

      {:ok, result} = ExVrp.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(1000))

      solution = result.best

      # With sufficient gap, all routes should be present and gap satisfied
      assert Solution.num_routes(solution) >= 1
      assert_gaps_enforced(solution, model)
    end

    test "route times are shifted when gap is insufficient but tw_late has room" do
      # Shift 1: [0, 100], Shift 2: [120, 500]
      # Route 1 ends around ~12, route 2 starts at 120, gap = ~108
      # With min_gap = 200, gap enforcement should shift route 2 forward
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 500)
        |> Model.add_client(
          x: 1,
          y: 0,
          tw_early: 0,
          tw_late: 500,
          service_duration: 10,
          delivery: [50],
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 1,
          y: 0,
          tw_early: 120,
          tw_late: 500,
          service_duration: 10,
          delivery: [50],
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 0,
          tw_late: 100
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 120,
          tw_late: 500
        )
        |> Model.add_vehicle_group(vehicle_types: [0, 1], min_gap: 200)

      {:ok, result} = ExVrp.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(1000))

      solution = result.best

      # Gap enforcement is baked into the solution — verify directly
      assert_gaps_enforced(solution, model)
    end

    test "route is dropped when shifting would exceed tw_late" do
      # Shift 1: [0, 50], Shift 2: [60, 80]
      # Route 1 ends around ~12, route 2 starts at 60, gap = ~48
      # With min_gap = 200, shift would push route 2 past tw_late=80 — dropped
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 200)
        |> Model.add_client(
          x: 1,
          y: 0,
          tw_early: 0,
          tw_late: 50,
          service_duration: 10,
          delivery: [50],
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 1,
          y: 0,
          tw_early: 60,
          tw_late: 80,
          service_duration: 10,
          delivery: [50],
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 0,
          tw_late: 50
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 60,
          tw_late: 80
        )
        |> Model.add_vehicle_group(vehicle_types: [0, 1], min_gap: 200)

      {:ok, result} = ExVrp.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(1000))

      solution = result.best

      # The solution should have at most 1 route (second one dropped)
      assert Solution.num_routes(solution) <= 1
    end

    test "ExVrp.solve/2 returns solution with gaps already enforced" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        |> Model.add_client(
          x: 1,
          y: 0,
          tw_early: 0,
          tw_late: 1000,
          service_duration: 10,
          delivery: [50],
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 0,
          tw_late: 500
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 600,
          tw_late: 1000
        )
        |> Model.add_vehicle_group(vehicle_types: [0, 1], min_gap: 50)

      {:ok, result} = ExVrp.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(200))

      # Result should not have gap_adjustments field
      refute Map.has_key?(result, :gap_adjustments)

      # Solution should have gaps enforced
      assert_gaps_enforced(result.best, model)
    end

    test "no vehicle groups returns solution unchanged" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = ExVrp.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))

      assert result.best
      assert Solution.feasible?(result.best)
    end
  end

  # Helper to verify all vehicle group gaps are satisfied in a solution.
  defp assert_gaps_enforced(solution, model) do
    num_routes = Solution.num_routes(solution)

    for group <- model.vehicle_groups do
      type_set = MapSet.new(group.vehicle_type_indices)

      route_times =
        0..(num_routes - 1)
        |> Enum.filter(fn idx ->
          Solution.route_vehicle_type(solution, idx) in type_set
        end)
        |> Enum.map(fn idx ->
          {Solution.route_start_time(solution, idx), Solution.route_end_time(solution, idx)}
        end)
        |> Enum.sort()

      for [{_s1, end1}, {start2, _e2}] <- Enum.chunk_every(route_times, 2, 1, :discard) do
        gap = start2 - end1

        assert gap >= group.min_gap,
               "Gap #{gap} between consecutive routes is less than min_gap #{group.min_gap}"
      end
    end
  end
end

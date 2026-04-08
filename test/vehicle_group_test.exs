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

  describe "solving with vehicle groups" do
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
end

defmodule ExVrp.MultiTripTest do
  @moduledoc """
  Tests for multi-trip VRP support.

  Multi-trip VRP allows vehicles to return to reload depots mid-route
  to pick up additional cargo for subsequent deliveries.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
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
      assert ExVrp.Solution.complete?(result.best)
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
      assert ExVrp.Solution.feasible?(result.best)
      assert ExVrp.Solution.complete?(result.best)
    end
  end
end

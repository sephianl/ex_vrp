defmodule ExVrp.VehicleTypeTest do
  @moduledoc """
  Tests ported from PyVRP's test_ProblemData.py - VehicleType tests
  """
  use ExUnit.Case, async: true

  alias ExVrp.VehicleType

  describe "new/1" do
    test "creates vehicle type with required fields" do
      vt = VehicleType.new(num_available: 3, capacity: [100])

      assert vt.num_available == 3
      assert vt.capacity == [100]
    end

    test "creates vehicle type with all fields" do
      # Ported from PyVRP test_vehicle_type_constructor
      vt =
        VehicleType.new(
          num_available: 7,
          start_depot: 29,
          end_depot: 43,
          capacity: [13],
          fixed_cost: 3,
          tw_early: 17,
          tw_late: 19,
          shift_duration: 23,
          max_distance: 31,
          unit_distance_cost: 37,
          unit_duration_cost: 41,
          start_late: 18,
          max_overtime: 43,
          name: "vehicle_type name"
        )

      assert vt.num_available == 7
      assert vt.start_depot == 29
      assert vt.end_depot == 43
      assert vt.capacity == [13]
      assert vt.fixed_cost == 3
      assert vt.tw_early == 17
      assert vt.tw_late == 19
      assert vt.shift_duration == 23
      assert vt.max_distance == 31
      assert vt.unit_distance_cost == 37
      assert vt.unit_duration_cost == 41
      assert vt.start_late == 18
      assert vt.max_overtime == 43
      assert vt.name == "vehicle_type name"
    end

    test "has sensible defaults" do
      vt = VehicleType.new(num_available: 1, capacity: [50])

      assert vt.start_depot == 0
      assert vt.end_depot == 0
      assert vt.fixed_cost == 0
      assert vt.tw_early == 0
      assert vt.tw_late == :infinity
      assert vt.shift_duration == :infinity
      assert vt.max_distance == :infinity
      assert vt.unit_distance_cost == 1
      assert vt.unit_duration_cost == 0
      assert vt.start_late == 0
      assert vt.max_overtime == 0
      assert vt.name == ""
    end

    test "supports multi-dimensional capacity" do
      # Ported from PyVRP test - vehicles can have multiple capacity dimensions
      vt = VehicleType.new(num_available: 2, capacity: [100, 50, 25])

      assert vt.capacity == [100, 50, 25]
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, fn ->
        VehicleType.new(num_available: 1)
      end

      assert_raise ArgumentError, fn ->
        VehicleType.new(capacity: [100])
      end
    end
  end
end

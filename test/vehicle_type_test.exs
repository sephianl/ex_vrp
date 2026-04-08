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

  describe "time_windows" do
    test "two windows produces one forbidden window" do
      vt = VehicleType.new(num_available: 1, capacity: [100], time_windows: [{0, 500}, {600, 1000}])

      assert vt.tw_early == 0
      assert vt.tw_late == 1000
      assert vt.forbidden_windows == [{500, 600}]
    end

    test "single window sets tw_early and tw_late with no forbidden windows" do
      vt = VehicleType.new(num_available: 1, capacity: [100], time_windows: [{100, 500}])

      assert vt.tw_early == 100
      assert vt.tw_late == 500
      assert vt.forbidden_windows == []
    end

    test "three windows produces two forbidden windows" do
      vt =
        VehicleType.new(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 100}, {200, 300}, {400, 500}]
        )

      assert vt.tw_early == 0
      assert vt.tw_late == 500
      assert vt.forbidden_windows == [{100, 200}, {300, 400}]
    end

    test "overlapping windows are merged" do
      vt = VehicleType.new(num_available: 1, capacity: [100], time_windows: [{0, 500}, {400, 600}])

      assert vt.tw_early == 0
      assert vt.tw_late == 600
      assert vt.forbidden_windows == []
    end

    test "adjacent windows are merged" do
      vt = VehicleType.new(num_available: 1, capacity: [100], time_windows: [{0, 500}, {500, 1000}])

      assert vt.tw_early == 0
      assert vt.tw_late == 1000
      assert vt.forbidden_windows == []
    end

    test "unsorted windows are sorted before processing" do
      vt = VehicleType.new(num_available: 1, capacity: [100], time_windows: [{600, 1000}, {0, 500}])

      assert vt.tw_early == 0
      assert vt.tw_late == 1000
      assert vt.forbidden_windows == [{500, 600}]
    end

    test "raises when combined with tw_early" do
      assert_raise ArgumentError, ~r/cannot specify :time_windows together with/, fn ->
        VehicleType.new(num_available: 1, capacity: [100], time_windows: [{0, 500}], tw_early: 0)
      end
    end

    test "raises when combined with tw_late" do
      assert_raise ArgumentError, ~r/cannot specify :time_windows together with/, fn ->
        VehicleType.new(num_available: 1, capacity: [100], time_windows: [{0, 500}], tw_late: 500)
      end
    end

    test "raises when combined with forbidden_windows" do
      assert_raise ArgumentError, ~r/cannot specify :time_windows together with/, fn ->
        VehicleType.new(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 500}],
          forbidden_windows: [{100, 200}]
        )
      end
    end

    test "raises on empty list" do
      assert_raise ArgumentError, ~r/non-empty list/, fn ->
        VehicleType.new(num_available: 1, capacity: [100], time_windows: [])
      end
    end

    test "raises on invalid window tuple" do
      assert_raise ArgumentError, ~r/invalid time window/, fn ->
        VehicleType.new(num_available: 1, capacity: [100], time_windows: [{500, 100}])
      end
    end

    test "forbidden_windows field works directly without time_windows" do
      vt =
        VehicleType.new(
          num_available: 1,
          capacity: [100],
          tw_early: 0,
          tw_late: 1000,
          forbidden_windows: [{500, 600}]
        )

      assert vt.tw_early == 0
      assert vt.tw_late == 1000
      assert vt.forbidden_windows == [{500, 600}]
    end
  end

  describe "time_windows integration" do
    alias ExVrp.Model
    alias ExVrp.Solution
    alias ExVrp.Solver

    test "vehicle with multiple time windows solves correctly" do
      # Vehicle operates in two windows: 0-500 and 700-1200
      # Client 1 must be served in first window (tw 0-400)
      # Client 2 must be served in second window (tw 800-1100)
      # The gap 500-700 is a forbidden window
      duration_matrix = [
        [0, 10, 10],
        [10, 0, 20],
        [10, 20, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1200)
        |> Model.add_client(x: 10, y: 0, delivery: [10], tw_early: 0, tw_late: 400, service_duration: 10)
        |> Model.add_client(x: 0, y: 10, delivery: [10], tw_early: 800, tw_late: 1100, service_duration: 10)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 500}, {700, 1200}]
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 500, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.complete?(solution)

      # Verify no visit starts during the forbidden window [500, 700)
      routes = Solution.routes(solution)

      for {_route, idx} <- Enum.with_index(routes) do
        schedule = Solution.route_schedule(solution, idx)

        for visit <- schedule do
          refute visit.start_service >= 500 and visit.start_service < 700,
                 "Visit at #{visit.start_service} falls in forbidden window [500, 700)"
        end
      end
    end
  end
end

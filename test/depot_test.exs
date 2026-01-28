defmodule ExVrp.DepotTest do
  @moduledoc """
  Tests ported from PyVRP's test_ProblemData.py - Depot tests
  """
  use ExUnit.Case, async: true

  alias ExVrp.Depot

  describe "new/1" do
    test "creates depot with required fields" do
      depot = Depot.new(x: 0, y: 0)

      assert depot.x == 0
      assert depot.y == 0
    end

    test "creates depot with all fields" do
      # Ported from PyVRP test_depot_constructor
      depot =
        Depot.new(
          x: 1.25,
          y: 0.5,
          tw_early: 5,
          tw_late: 7,
          name: "test"
        )

      assert depot.x == 1.25
      assert depot.y == 0.5
      assert depot.tw_early == 5
      assert depot.tw_late == 7
      assert depot.name == "test"
    end

    test "has sensible defaults" do
      depot = Depot.new(x: 0, y: 0)

      assert depot.tw_early == 0
      assert depot.tw_late == :infinity
      assert depot.service_duration == 0
      assert depot.reload_cost == 0
      assert depot.name == ""
    end

    test "creates depot with reload_cost" do
      depot =
        Depot.new(
          x: 0,
          y: 0,
          service_duration: 10,
          reload_cost: 50
        )

      assert depot.service_duration == 10
      assert depot.reload_cost == 50
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, fn ->
        Depot.new(x: 1)
      end

      assert_raise ArgumentError, fn ->
        Depot.new(y: 1)
      end
    end
  end
end

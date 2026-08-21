defmodule ExVrp.DepotTest do
  @moduledoc """
  Tests ported from PyVRP's test_ProblemData.py - Depot tests
  """
  use ExUnit.Case, async: true

  alias ExVrp.Depot

  describe "new/1" do
    test "creates depot with required fields" do
      depot = Depot.new([])
    end

    test "creates depot with all fields" do
      # Ported from PyVRP test_depot_constructor
      depot =
        Depot.new(
          tw_early: 5,
          tw_late: 7,
          name: "test"
        )

      assert depot.tw_early == 5
      assert depot.tw_late == 7
      assert depot.name == "test"
    end

    test "has sensible defaults" do
      depot = Depot.new([])

      assert depot.tw_early == 0
      assert depot.tw_late == :infinity
      assert depot.service_duration == 0
      assert depot.reload_cost == 0
      assert depot.name == ""
    end

    test "creates depot with reload_cost" do
      depot =
        Depot.new(
          service_duration: 10,
          reload_cost: 50
        )

      assert depot.service_duration == 10
      assert depot.reload_cost == 50
    end
  end
end

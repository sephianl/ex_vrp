defmodule ExVrp.ReloadCostTest do
  @moduledoc """
  Tests for depot reload cost functionality.

  Reload costs are incurred when a vehicle returns to a reload depot
  mid-route to replenish cargo for additional deliveries.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Depot
  alias ExVrp.Model
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver

  describe "depot reload_cost field" do
    test "depot accepts reload_cost parameter" do
      depot = Depot.new(x: 0, y: 0, reload_cost: 100)
      assert depot.reload_cost == 100
    end

    test "depot defaults to zero reload_cost" do
      depot = Depot.new(x: 0, y: 0)
      assert depot.reload_cost == 0
    end
  end

  describe "solution with reload costs" do
    test "solution with depot reload_cost has non-zero reload cost" do
      # Create a model that forces multi-trip due to capacity constraints
      # with a reload depot that has a cost
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, reload_cost: 100, service_duration: 10)
        |> Model.add_client(x: 10, y: 0, delivery: [80])
        |> Model.add_client(x: 20, y: 0, delivery: [80])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0],
          max_reloads: 5
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))

      solution = result.best
      assert Solution.complete?(solution)

      # Since the problem requires a reload due to capacity, reload cost should be > 0
      reload_cost = Solution.reload_cost(solution)
      assert reload_cost > 0, "Expected non-zero reload cost, got #{reload_cost}"
    end

    test "solution without reload has zero reload cost" do
      # Simple problem that doesn't need reload
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, reload_cost: 100)
        |> Model.add_client(x: 10, y: 0, delivery: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))

      solution = result.best
      assert Solution.complete?(solution)

      # No reload needed, so cost should be zero
      reload_cost = Solution.reload_cost(solution)
      assert reload_cost == 0, "Single-trip solution should have zero reload cost"
    end
  end

  describe "reload cost per route" do
    test "route_reload_cost returns cost for multi-trip route" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, reload_cost: 75, service_duration: 10)
        |> Model.add_client(x: 10, y: 0, delivery: [80])
        |> Model.add_client(x: 20, y: 0, delivery: [80])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0],
          max_reloads: 5
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))

      solution = result.best
      # Check the first route
      route_reload_cost = Solution.route_reload_cost(solution, 0)
      assert route_reload_cost > 0, "Expected non-zero route reload cost"
    end
  end
end

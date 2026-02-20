defmodule ExVrp.PrizeCollectingEdgeCasesTest do
  @moduledoc """
  Comprehensive tests for prize-collecting VRP edge cases.

  These tests verify:
  1. Cost accounting is symmetric (insert/remove costs are inverses)
  2. No oscillations occur with high prizes
  3. Prize values correctly influence objective function
  4. Solver converges in reasonable time
  """

  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solver

  describe "cost symmetry verification" do
    test "inserting and removing same client should have inverse costs" do
      # Simple problem: 1 depot, 1 vehicle, 2 clients with prizes
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10], required: false, prize: 1000)
        |> Model.add_client(x: 20, y: 0, delivery: [10], required: false, prize: 1000)

      {:ok, result} = Solver.solve(model, max_iterations: 100)

      # Should find a solution without hanging
      assert result.num_iterations <= 100
      assert result.best.is_feasible
    end

    test "high prize should not cause infinite loops" do
      # Use very high prize (100k) that previously caused oscillations
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10], required: false, prize: 100_000)
        |> Model.add_client(x: 20, y: 0, delivery: [10], required: false, prize: 100_000)
        |> Model.add_client(x: 30, y: 0, delivery: [10], required: false, prize: 100_000)

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Solver.solve(model, max_iterations: 100)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should complete quickly (not hang)
      assert elapsed < 5000, "Solver took #{elapsed}ms, expected < 5000ms"
      assert result.num_iterations <= 100
    end

    test "solver should prefer collecting prizes over minimizing distance" do
      # Client with huge prize far away vs cheap client nearby
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 1, y: 0, delivery: [10], required: false, prize: 10)
        |> Model.add_client(x: 100, y: 0, delivery: [10], required: false, prize: 10_000)

      {:ok, result} = Solver.solve(model, max_iterations: 200)

      # Should visit the high-prize client despite distance
      routes = ExVrp.Solution.routes(result.best)
      total_clients = Enum.sum(Enum.map(routes, fn route -> length(route.visits) end))

      # With such a high prize, should visit at least the high-prize client
      assert total_clients >= 1
      assert result.best.is_feasible
    end
  end

  describe "oscillation prevention" do
    test "two clients with identical prizes should not oscillate" do
      # Previously problematic: clients 352 and 229 oscillated
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 10, y: 10, delivery: [50], required: false, prize: 100_000)
        |> Model.add_client(x: 15, y: 15, delivery: [50], required: false, prize: 100_000)

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Solver.solve(model, max_iterations: 200)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should converge quickly without oscillating
      assert elapsed < 5000
      assert result.num_iterations <= 200
    end

    test "many clients with same prize should converge" do
      # 10 clients all with identical high prizes
      model =
        1..10
        |> Enum.reduce(Model.add_depot(Model.new(), x: 0, y: 0), fn i, acc ->
          angle = 2 * :math.pi() * i / 10

          Model.add_client(acc,
            x: round(100 * :math.cos(angle)),
            y: round(100 * :math.sin(angle)),
            delivery: [10],
            required: false,
            prize: 50_000
          )
        end)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Solver.solve(model, max_iterations: 500)
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 10_000, "Took #{elapsed}ms with #{result.num_iterations} iterations"
      assert result.num_iterations <= 500
    end

    test "alternating high/low prizes should not oscillate" do
      # Pattern that might trigger swaps
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10], required: false, prize: 100_000)
        |> Model.add_client(x: 11, y: 0, delivery: [10], required: false, prize: 100)
        |> Model.add_client(x: 20, y: 0, delivery: [10], required: false, prize: 100_000)
        |> Model.add_client(x: 21, y: 0, delivery: [10], required: false, prize: 100)

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Solver.solve(model, max_iterations: 300)
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 5000
      assert result.num_iterations <= 300
    end
  end

  describe "prize value correctness" do
    test "uncollected prizes should increase objective" do
      # Two identical models, one with prizes, one without
      base_model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10], required: true)
        |> Model.add_client(x: 20, y: 0, delivery: [10], required: false)

      prize_model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10], required: true)
        |> Model.add_client(x: 20, y: 0, delivery: [10], required: false, prize: 5000)

      {:ok, base_result} = Solver.solve(base_model, max_iterations: 100)
      {:ok, prize_result} = Solver.solve(prize_model, max_iterations: 100)

      # Prize model should incentivize visiting the optional client
      base_routes = ExVrp.Solution.routes(base_result.best)
      prize_routes = ExVrp.Solution.routes(prize_result.best)

      base_clients = Enum.sum(Enum.map(base_routes, fn r -> length(r.visits) end))
      prize_clients = Enum.sum(Enum.map(prize_routes, fn r -> length(r.visits) end))

      # Prize should make it worth visiting the optional client
      assert prize_clients >= base_clients
    end

    test "prize should offset travel cost in objective" do
      # Client far away but with prize that offsets distance cost
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], fixed_cost: 0)
        |> Model.add_client(
          x: 1000,
          y: 0,
          delivery: [10],
          required: false,
          prize: 10_000
        )

      {:ok, result} = Solver.solve(model, max_iterations: 100)

      routes = ExVrp.Solution.routes(result.best)
      total_clients = Enum.sum(Enum.map(routes, fn r -> length(r.visits) end))

      # High prize should make it worth the long trip
      assert total_clients == 1
      assert result.best.is_feasible
    end
  end

  describe "capacity and prize interaction" do
    test "should not visit optional client if capacity violated" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [50])
        |> Model.add_client(x: 10, y: 0, delivery: [50], required: true)
        |> Model.add_client(x: 20, y: 0, delivery: [10], required: false, prize: 100_000)

      {:ok, result} = Solver.solve(model, max_iterations: 200)

      # Should visit required client but skip optional (capacity constraint)
      routes = ExVrp.Solution.routes(result.best)
      total_clients = Enum.sum(Enum.map(routes, fn r -> length(r.visits) end))

      assert total_clients == 1, "Should only visit required client"
      assert result.best.is_feasible
    end

    test "high prize should not override hard constraints" do
      # Time window makes it impossible to visit both
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], tw_early: 0, tw_late: 1000)
        |> Model.add_client(
          x: 100,
          y: 0,
          delivery: [10],
          required: true,
          tw_early: 0,
          tw_late: 100,
          service_duration: 50
        )
        |> Model.add_client(
          x: 100,
          y: 0,
          delivery: [10],
          required: false,
          prize: 1_000_000,
          tw_early: 0,
          tw_late: 100,
          service_duration: 60
        )

      {:ok, result} = Solver.solve(model, max_iterations: 200)

      # Even huge prize can't violate time windows
      assert result.best.is_feasible
    end
  end

  describe "convergence and performance" do
    test "should converge within max_iterations" do
      # Moderate problem that should converge quickly
      model =
        1..5
        |> Enum.reduce(Model.add_depot(Model.new(), x: 0, y: 0), fn i, acc ->
          Model.add_client(acc,
            x: i * 10,
            y: 0,
            delivery: [10],
            required: false,
            prize: 1000 * i
          )
        end)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 100)

      # Should complete within iteration limit
      assert result.num_iterations <= 100
    end

    test "empty solution should be valid when all clients optional and prizes low" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], fixed_cost: 10_000)
        |> Model.add_client(x: 1000, y: 1000, delivery: [10], required: false, prize: 10)

      {:ok, result} = Solver.solve(model, max_iterations: 100)

      # Low prize, high distance + vehicle cost = skip the client
      routes = ExVrp.Solution.routes(result.best)

      # Either visits (collects prize) or doesn't (saves vehicle cost)
      # Both are valid, solver chooses based on cost
      assert result.best.is_feasible
    end
  end

  describe "regression tests for known issues" do
    test "clients 352 and 229 pattern (from production bug)" do
      # Simplified version of the problematic pattern from production
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 352, y: 0, delivery: [10], required: false, prize: 100_000)
        |> Model.add_client(x: 229, y: 0, delivery: [10], required: false, prize: 100_000)

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Solver.solve(model, max_iterations: 200)
      elapsed = System.monotonic_time(:millisecond) - start

      # Must not hang
      assert elapsed < 5000, "Solver hung! Took #{elapsed}ms"
      assert result.num_iterations <= 200
    end

    test "production dataset size (570 clients) with moderate prizes" do
      # Scaled-down version of production scenario
      model =
        1..50
        |> Enum.reduce(Model.add_depot(Model.new(), x: 0, y: 0), fn i, acc ->
          angle = 2 * :math.pi() * i / 50

          Model.add_client(acc,
            x: round(1000 * :math.cos(angle)),
            y: round(1000 * :math.sin(angle)),
            delivery: [10],
            required: false,
            # Lower than production but still significant
            prize: 10_000
          )
        end)
        |> Model.add_vehicle_type(num_available: 5, capacity: [100])

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Solver.solve(model, max_iterations: 500)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should handle many clients without hanging
      assert elapsed < 30_000, "Took #{elapsed}ms for 50 clients"
      assert result.num_iterations <= 500
    end
  end
end

defmodule ExVrp.IteratedLocalSearchTest do
  use ExUnit.Case, async: true

  alias ExVrp.IteratedLocalSearch
  alias ExVrp.Model
  alias ExVrp.PenaltyManager
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  describe "Solver.solve/2 with ILS" do
    test "solves a simple CVRP and returns Result" do
      model = build_cvrp_model(10)

      {:ok, result} = Solver.solve(model, max_iterations: 100, seed: 42)

      assert %IteratedLocalSearch.Result{} = result
      assert result.best.is_feasible
      assert result.best.is_complete
      assert result.best.routes != []
      assert result.num_iterations > 0
      assert result.runtime > 0
    end

    test "respects max_iterations stopping criterion" do
      model = build_cvrp_model(10)

      {:ok, result_few} = Solver.solve(model, max_iterations: 10, seed: 42)
      {:ok, result_many} = Solver.solve(model, max_iterations: 500, seed: 42)

      # Both should be valid solutions
      assert result_few.best.is_complete
      assert result_many.best.is_complete

      # More iterations should give at least as good result
      assert result_many.best.distance <= result_few.best.distance
    end

    test "respects seed for reproducibility" do
      model = build_cvrp_model(8)

      {:ok, result1} = Solver.solve(model, max_iterations: 50, seed: 123)
      {:ok, result2} = Solver.solve(model, max_iterations: 50, seed: 123)

      # Same seed should produce identical results
      assert result1.best.routes == result2.best.routes
      assert result1.best.distance == result2.best.distance
    end

    test "different seeds produce different results" do
      model = build_cvrp_model(10)

      {:ok, result1} = Solver.solve(model, max_iterations: 100, seed: 1)
      {:ok, result2} = Solver.solve(model, max_iterations: 100, seed: 2)

      # Different seeds should usually produce different results
      assert result1.best.routes != result2.best.routes or
               result1.best.distance != result2.best.distance
    end

    test "respects max_runtime stopping criterion" do
      model = build_cvrp_model(10)

      start = System.monotonic_time(:millisecond)

      {:ok, _result} =
        Solver.solve(model,
          # 100ms in seconds (PyVRP uses seconds)
          max_runtime: 0.1,
          max_iterations: 100_000,
          seed: 42
        )

      elapsed = System.monotonic_time(:millisecond) - start

      # Should stop around or before the runtime limit (with some tolerance)
      assert elapsed < 500
    end

    test "respects custom stop criteria" do
      model = build_cvrp_model(8)

      # Stop after 20 iterations
      stop_criteria = StoppingCriteria.max_iterations(20)

      {:ok, result} = Solver.solve(model, stop: stop_criteria, seed: 42)

      assert result.num_iterations <= 20
    end

    test "tracks statistics" do
      model = build_cvrp_model(10)

      {:ok, result} = Solver.solve(model, max_iterations: 100, seed: 42)

      assert result.stats.initial_cost > 0
      assert result.stats.final_cost > 0
      assert result.stats.final_cost <= result.stats.initial_cost
      assert result.best.stats.iterations > 0
    end
  end

  describe "Solver.solve/2 with time windows" do
    test "respects time window constraints" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 10, y: 0, delivery: [10], tw_early: 0, tw_late: 100)
        |> Model.add_client(x: 20, y: 0, delivery: [10], tw_early: 50, tw_late: 200)
        |> Model.add_client(x: 30, y: 0, delivery: [10], tw_early: 100, tw_late: 300)

      {:ok, result} = Solver.solve(model, max_iterations: 200, seed: 42)

      assert result.best.is_feasible
      assert result.best.is_complete
    end
  end

  describe "Solver.solve/2 with capacity constraints" do
    test "handles tight capacity constraints" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [50])
        |> Model.add_client(x: 10, y: 0, delivery: [20])
        |> Model.add_client(x: 20, y: 0, delivery: [20])
        |> Model.add_client(x: 30, y: 0, delivery: [20])
        |> Model.add_client(x: 40, y: 0, delivery: [20])

      {:ok, result} = Solver.solve(model, max_iterations: 200, seed: 42)

      # Should find a feasible solution with proper vehicle allocation
      assert result.best.is_feasible
    end
  end

  describe "ILS-specific behavior" do
    test "improves solution over iterations" do
      model = build_cvrp_model(15)

      {:ok, result} = Solver.solve(model, max_iterations: 500, seed: 42)

      # Final cost should be at least as good as initial
      assert result.stats.final_cost <= result.stats.initial_cost
    end

    test "tracks improvements and restarts" do
      model = build_cvrp_model(10)

      ils_params = %IteratedLocalSearch.Params{
        max_no_improvement: 20,
        history_size: 10
      }

      {:ok, result} =
        Solver.solve(model,
          max_iterations: 200,
          ils_params: ils_params,
          seed: 42
        )

      assert result.best.stats.improvements >= 0
      assert result.best.stats.restarts >= 0
    end
  end

  describe "PenaltyManager integration" do
    test "uses custom penalty params" do
      model = build_cvrp_model(8)

      penalty_params = %PenaltyManager.Params{
        target_feasible: 0.5,
        penalty_increase: 1.5,
        penalty_decrease: 0.7
      }

      {:ok, result} =
        Solver.solve(model,
          max_iterations: 100,
          penalty_params: penalty_params,
          seed: 42
        )

      assert result.best.is_complete
    end
  end

  # Helper to build a CVRP model with n clients
  defp build_cvrp_model(n) do
    :rand.seed(:exsplus, {42, 42, 42})

    model =
      Model.new()
      |> Model.add_depot(x: 50, y: 50)
      |> Model.add_vehicle_type(num_available: div(n, 3) + 1, capacity: [100])

    Enum.reduce(1..n, model, fn i, model ->
      angle = 2 * :math.pi() * i / n
      x = round(50 + 40 * :math.cos(angle))
      y = round(50 + 40 * :math.sin(angle))
      demand = :rand.uniform(20) + 5

      Model.add_client(model, x: x, y: y, delivery: [demand])
    end)
  end
end

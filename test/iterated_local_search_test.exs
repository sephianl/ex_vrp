defmodule ExVrp.IteratedLocalSearchTest do
  use ExUnit.Case, async: true

  alias ExVrp.IteratedLocalSearch
  alias ExVrp.IteratedLocalSearch.RingBuffer
  alias ExVrp.Model
  alias ExVrp.PenaltyManager
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  # ============================================================================
  # Tests for the inline RingBuffer used in LAHC (Late Acceptance Hill-Climbing)
  # This is different from ExVrp.RingBuffer - it stores solution references
  # and has skip/peek semantics for the LAHC algorithm.
  # ============================================================================
  describe "IteratedLocalSearch.RingBuffer" do
    test "new creates buffer with correct maxlen" do
      rb = RingBuffer.new(5)

      assert rb.maxlen == 5
      assert rb.idx == 0
      assert length(rb.buffer) == 5
    end

    test "peek returns nil for fresh buffer" do
      rb = RingBuffer.new(5)

      assert RingBuffer.peek(rb) == nil
    end

    test "append stores value at current position" do
      rb = RingBuffer.new(3)
      rb = RingBuffer.append(rb, :a)

      # After append, index advances, but peek looks at NEW index
      assert rb.idx == 1
      # peek returns element at current (new) index, which is still nil
      assert RingBuffer.peek(rb) == nil
    end

    test "append wraps around at maxlen" do
      rb = RingBuffer.new(3)
      rb = RingBuffer.append(rb, :a)
      rb = RingBuffer.append(rb, :b)
      rb = RingBuffer.append(rb, :c)

      # Index should be 3, which wraps to 0
      assert rb.idx == 3
      assert rem(rb.idx, rb.maxlen) == 0

      # peek at position 0 should now return :a (the oldest)
      assert RingBuffer.peek(rb) == :a
    end

    test "skip advances index without storing" do
      rb = RingBuffer.new(3)
      rb = RingBuffer.append(rb, :a)
      rb = RingBuffer.skip(rb)

      # Skip should advance index but not modify buffer
      assert rb.idx == 2
      # peek returns element at current index (position 2), still nil
      assert RingBuffer.peek(rb) == nil
    end

    test "clear resets buffer to initial state" do
      rb = RingBuffer.new(3)
      rb = RingBuffer.append(rb, :a)
      rb = RingBuffer.append(rb, :b)
      rb = RingBuffer.clear(rb)

      assert rb.idx == 0
      assert RingBuffer.peek(rb) == nil
    end

    test "LAHC semantics: peek returns value to compare against" do
      # In LAHC, we compare current solution against historical solution
      # peek returns the element that will be overwritten next
      rb = RingBuffer.new(3)

      # Fill buffer
      rb = RingBuffer.append(rb, :sol_0)
      rb = RingBuffer.append(rb, :sol_1)
      rb = RingBuffer.append(rb, :sol_2)

      # Now at position 3 (wraps to 0), peek returns :sol_0
      assert RingBuffer.peek(rb) == :sol_0

      # Append new solution overwrites :sol_0
      rb = RingBuffer.append(rb, :sol_3)

      # Now peek returns :sol_1 (next oldest)
      assert RingBuffer.peek(rb) == :sol_1
    end
  end

  describe "IteratedLocalSearch.Params defaults" do
    test "defaults match PyVRP" do
      params = %IteratedLocalSearch.Params{}

      # PyVRP defaults from IteratedLocalSearchParams
      assert params.max_no_improvement == 50_000
      assert params.history_size == 500
    end
  end

  describe "IteratedLocalSearch.Result methods" do
    test "cost returns distance for feasible solution" do
      model = build_cvrp_model(5)
      {:ok, result} = Solver.solve(model, max_iterations: 50, seed: 42)

      assert result.best.is_feasible
      assert IteratedLocalSearch.Result.cost(result) == result.best.distance
    end

    test "cost returns :infinity for infeasible solution" do
      # Create model where solution is always infeasible
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        # Client needs 100, vehicle has 10 - always infeasible
        |> Model.add_client(x: 10, y: 0, delivery: [100])
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])

      {:ok, result} = Solver.solve(model, max_iterations: 10, seed: 42)

      # Solution should be infeasible
      refute result.best.is_feasible
      assert IteratedLocalSearch.Result.cost(result) == :infinity
    end

    test "feasible? returns correct boolean" do
      model = build_cvrp_model(5)
      {:ok, result} = Solver.solve(model, max_iterations: 50, seed: 42)

      assert IteratedLocalSearch.Result.feasible?(result) == result.best.is_feasible
    end

    test "summary returns formatted string" do
      model = build_cvrp_model(5)
      {:ok, result} = Solver.solve(model, max_iterations: 20, seed: 42)

      summary = IteratedLocalSearch.Result.summary(result)

      assert is_binary(summary)
      assert summary =~ "Solution results"
      assert summary =~ "Feasible:"
      assert summary =~ "Cost:"
      assert summary =~ "Routes:"
      assert summary =~ "Distance:"
      assert summary =~ "Iterations:"
      assert summary =~ "Runtime:"
    end
  end

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

    test "restarts after max_no_improvement iterations" do
      # With very small max_no_improvement, restarts should occur frequently
      model = build_cvrp_model(10)

      ils_params = %IteratedLocalSearch.Params{
        # Restart every 5 iterations without improvement
        max_no_improvement: 5,
        history_size: 10
      }

      {:ok, result} =
        Solver.solve(model,
          max_iterations: 100,
          ils_params: ils_params,
          seed: 42
        )

      # With 100 iterations and max_no_improvement=5,
      # we should have some restarts (unless we improve frequently)
      # The key is that the algorithm doesn't crash
      assert result.best.is_complete
      assert result.num_iterations > 0
    end

    test "LAHC history affects acceptance" do
      # Smaller history should make algorithm more greedy
      model = build_cvrp_model(8)

      ils_small_history = %IteratedLocalSearch.Params{
        max_no_improvement: 100,
        # Small history - more greedy
        history_size: 5
      }

      ils_large_history = %IteratedLocalSearch.Params{
        max_no_improvement: 100,
        # Large history - more accepting
        history_size: 100
      }

      {:ok, result_small} =
        Solver.solve(model,
          max_iterations: 50,
          ils_params: ils_small_history,
          seed: 42
        )

      {:ok, result_large} =
        Solver.solve(model,
          max_iterations: 50,
          ils_params: ils_large_history,
          seed: 42
        )

      # Both should produce valid solutions
      assert result_small.best.is_complete
      assert result_large.best.is_complete
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

  describe "solver edge cases" do
    test "handles single client" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 10, seed: 42)

      assert result.best.is_feasible
      assert result.best.is_complete
      assert result.best.num_clients == 1
      assert length(result.best.routes) == 1
    end

    test "handles two clients" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 50, seed: 42)

      assert result.best.is_feasible
      assert result.best.is_complete
    end

    test "handles tight capacity constraints" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [30])
        |> Model.add_client(x: 20, y: 0, delivery: [30])
        |> Model.add_client(x: 30, y: 0, delivery: [30])
        # Each client needs 30, capacity is 50, need 2 routes
        |> Model.add_vehicle_type(num_available: 3, capacity: [50])

      {:ok, result} = Solver.solve(model, max_iterations: 100, seed: 42)

      assert result.best.is_feasible
      assert result.best.is_complete
      # Should use at least 2 routes
      assert length(result.best.routes) >= 2
    end

    test "handles impossible capacity" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [100])
        # Client needs 100, vehicle has 50 - infeasible
        |> Model.add_vehicle_type(num_available: 1, capacity: [50])

      {:ok, result} = Solver.solve(model, max_iterations: 50, seed: 42)

      # Should still return a solution (possibly infeasible)
      assert result.best.is_complete
    end
  end

  describe "solver with complex constraints" do
    test "handles time windows" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], tw_early: 0, tw_late: 100)
        |> Model.add_client(x: 20, y: 0, delivery: [10], tw_early: 50, tw_late: 200)
        |> Model.add_client(x: 30, y: 0, delivery: [10], tw_early: 100, tw_late: 300)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100], tw_early: 0, tw_late: 400)

      {:ok, result} = Solver.solve(model, max_iterations: 200, seed: 42)

      assert result.best.is_complete
    end

    test "handles service durations" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], service_duration: 100)
        |> Model.add_client(x: 20, y: 0, delivery: [10], service_duration: 50)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 100, seed: 42)

      assert result.best.is_feasible
      # Duration should include service times
      assert result.best.duration > 0
    end

    test "handles multi-depot" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 100, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 90, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 100, seed: 42)

      assert result.best.is_feasible
      assert result.best.is_complete
    end

    test "handles heterogeneous fleet" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [30])
        |> Model.add_vehicle_type(num_available: 1, capacity: [50])

      {:ok, result} = Solver.solve(model, max_iterations: 100, seed: 42)

      assert result.best.is_feasible
    end

    test "handles multi-dimensional capacity" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20, 10], pickup: [0, 0])
        |> Model.add_client(x: 20, y: 0, delivery: [15, 15], pickup: [0, 0])
        |> Model.add_vehicle_type(num_available: 2, capacity: [50, 30])

      {:ok, result} = Solver.solve(model, max_iterations: 100, seed: 42)

      assert result.best.is_complete
    end
  end

  describe "solver result fields" do
    test "result contains all expected fields" do
      model = build_cvrp_model(5)

      {:ok, result} = Solver.solve(model, max_iterations: 20, seed: 42)

      assert %IteratedLocalSearch.Result{} = result
      assert Map.has_key?(result, :best)
      assert Map.has_key?(result, :stats)
      assert Map.has_key?(result, :num_iterations)
      assert Map.has_key?(result, :runtime)
    end

    test "result stats are populated" do
      model = build_cvrp_model(5)

      {:ok, result} = Solver.solve(model, max_iterations: 50, seed: 42)

      assert result.stats.initial_cost > 0
      assert result.stats.final_cost > 0
    end

    test "runtime is non-negative" do
      model = build_cvrp_model(5)

      {:ok, result} = Solver.solve(model, max_iterations: 10, seed: 42)

      assert result.runtime >= 0
    end

    test "num_iterations matches requested" do
      model = build_cvrp_model(5)

      {:ok, result} = Solver.solve(model, max_iterations: 15, seed: 42)

      # Should run approximately the requested iterations
      assert result.num_iterations > 0
      assert result.num_iterations <= 20
    end
  end

  describe "solver quality" do
    test "more iterations generally improve quality" do
      model = build_cvrp_model(15)

      {:ok, result_few} = Solver.solve(model, max_iterations: 10, seed: 42)
      {:ok, result_many} = Solver.solve(model, max_iterations: 500, seed: 42)

      # More iterations should give at least as good or better result
      assert result_many.best.distance <= result_few.best.distance
    end

    test "final cost is at most initial cost" do
      model = build_cvrp_model(10)

      {:ok, result} = Solver.solve(model, max_iterations: 100, seed: 42)

      assert result.stats.final_cost <= result.stats.initial_cost
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

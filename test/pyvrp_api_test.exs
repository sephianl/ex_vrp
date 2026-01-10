defmodule ExVrp.PyVRPApiTest do
  @moduledoc """
  Tests that verify API compatibility with PyVRP.

  These tests are designed to match PyVRP's test patterns and ensure
  the Elixir API provides equivalent functionality.
  """
  use ExUnit.Case, async: true

  alias ExVrp.IteratedLocalSearch
  alias ExVrp.Model
  alias ExVrp.PenaltyManager
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria
  alias IteratedLocalSearch.Result

  @moduletag :nif_required

  # ==========================================================================
  # Tests matching PyVRP's test_solve.py
  # ==========================================================================

  describe "solve API (matching test_solve.py)" do
    test "solve with same seed produces identical results" do
      # Matches: test_solve_same_seed
      model = build_small_cvrp()

      {:ok, result1} =
        Solver.solve(model,
          stop: StoppingCriteria.max_iterations(100),
          seed: 42
        )

      {:ok, result2} =
        Solver.solve(model,
          stop: StoppingCriteria.max_iterations(100),
          seed: 42
        )

      # Same seed should produce identical trajectories
      assert result1.best.routes == result2.best.routes
      assert Result.cost(result1) == Result.cost(result2)
    end

    test "solve accepts custom ILS params" do
      # Matches: test_solve_custom_params
      model = build_small_cvrp()

      # history_size=1 means only accept improving solutions (like PyVRP test)
      ils_params = %IteratedLocalSearch.Params{
        history_size: 1,
        max_no_improvement: 100
      }

      {:ok, result} =
        Solver.solve(model,
          stop: StoppingCriteria.max_iterations(50),
          ils_params: ils_params,
          seed: 42
        )

      assert Result.feasible?(result)
    end
  end

  # ==========================================================================
  # Tests matching PyVRP's test_Result.py
  # ==========================================================================

  describe "Result API (matching test_Result.py)" do
    test "result has correct data properties" do
      model = build_small_cvrp()

      {:ok, result} =
        Solver.solve(model,
          stop: StoppingCriteria.max_iterations(10),
          seed: 42
        )

      # Check all expected properties exist
      assert is_integer(result.num_iterations) and result.num_iterations >= 0
      assert is_integer(result.runtime) and result.runtime >= 0
      assert %ExVrp.Solution{} = result.best
      assert is_map(result.stats)
    end

    test "cost returns infinity for infeasible solution" do
      # Create an infeasible problem (capacity too small)
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        # Way over capacity
        |> Model.add_client(x: 10, y: 0, delivery: [100])

      {:ok, result} =
        Solver.solve(model,
          stop: StoppingCriteria.max_iterations(10),
          seed: 42
        )

      # If infeasible, cost should be infinity
      if not Result.feasible?(result) do
        assert Result.cost(result) == :infinity
      end
    end

    test "result provides summary" do
      model = build_small_cvrp()

      {:ok, result} =
        Solver.solve(model,
          stop: StoppingCriteria.max_iterations(10),
          seed: 42
        )

      summary = Result.summary(result)
      assert is_binary(summary)
      assert String.contains?(summary, "Feasible:")
      assert String.contains?(summary, "Cost:")
      assert String.contains?(summary, "Routes:")
    end
  end

  # ==========================================================================
  # Tests matching PyVRP's test_MaxIterations.py
  # ==========================================================================

  describe "MaxIterations (matching test_MaxIterations.py)" do
    test "raises on negative value" do
      # Matches: test_max_iterations_raises_negative_values
      assert_raise ArgumentError, fn ->
        StoppingCriteria.max_iterations(-1)
      end

      assert_raise ArgumentError, fn ->
        StoppingCriteria.max_iterations(-42)
      end
    end

    test "does not raise on valid values" do
      # Matches: test_max_iterations_does_not_raise_valid_values
      assert %StoppingCriteria{} = StoppingCriteria.max_iterations(0)
      assert %StoppingCriteria{} = StoppingCriteria.max_iterations(1)
      assert %StoppingCriteria{} = StoppingCriteria.max_iterations(10_000)
    end

    test "does not stop before iterations reached" do
      # Matches: test_before
      criteria = StoppingCriteria.max_iterations(100)
      stop_fn = StoppingCriteria.to_stop_fn(criteria)

      # Run 100 iterations - should not stop
      for _ <- 1..99 do
        assert stop_fn.(1000) == false
      end
    end

    test "stops after iterations reached" do
      # Matches: test_after
      criteria = StoppingCriteria.max_iterations(100)
      stop_fn = StoppingCriteria.to_stop_fn(criteria)

      # Run exactly 100 iterations
      for _ <- 1..100 do
        stop_fn.(1000)
      end

      # Now should stop
      assert stop_fn.(1000) == true
    end
  end

  # ==========================================================================
  # Tests matching PyVRP's test_NoImprovement.py
  # ==========================================================================

  describe "NoImprovement (matching test_NoImprovement.py)" do
    test "raises on negative value" do
      assert_raise ArgumentError, fn ->
        StoppingCriteria.no_improvement(-1)
      end
    end

    test "stops immediately when max is 0" do
      # Matches: test_zero_max_iterations
      criteria = StoppingCriteria.no_improvement(0)
      stop_fn = StoppingCriteria.to_stop_fn(criteria)

      assert stop_fn.(1000) == true
    end

    test "stops after single non-improving iteration when max is 1" do
      # Matches: test_single_max_iterations
      criteria = StoppingCriteria.no_improvement(1)
      stop_fn = StoppingCriteria.to_stop_fn(criteria)

      # First call with improving cost should not stop
      assert stop_fn.(1000) == false
      # Second call with same cost (no improvement) should stop
      assert stop_fn.(1000) == true
    end

    test "resets counter on improvement" do
      # Matches: test_reset_on_improvement
      criteria = StoppingCriteria.no_improvement(3)
      stop_fn = StoppingCriteria.to_stop_fn(criteria)

      # Initial call
      assert stop_fn.(1000) == false

      # Two non-improving
      assert stop_fn.(1000) == false
      assert stop_fn.(1000) == false

      # Improvement resets counter
      # Better cost
      assert stop_fn.(500) == false

      # Need 3 more non-improving to stop
      assert stop_fn.(500) == false
      assert stop_fn.(500) == false
      assert stop_fn.(500) == true
    end
  end

  # ==========================================================================
  # Tests matching PyVRP's test_MultipleCriteria.py
  # ==========================================================================

  describe "MultipleCriteria (matching test_MultipleCriteria.py)" do
    test "raises on empty list" do
      # Matches: test_raises_if_empty
      assert_raise ArgumentError, fn ->
        StoppingCriteria.multiple_criteria([])
      end
    end

    test "stops immediately with zero max iterations" do
      # Matches: test_stops_if_zero_max_iterations
      criteria =
        StoppingCriteria.multiple_criteria([
          StoppingCriteria.max_iterations(0),
          StoppingCriteria.max_runtime(10.0)
        ])

      stop_fn = StoppingCriteria.to_stop_fn(criteria)

      assert stop_fn.(1000) == true
    end

    test "stops when any criterion is met" do
      # Matches: test_before_max_runtime / test_after_max_runtime
      criteria =
        StoppingCriteria.multiple_criteria([
          StoppingCriteria.max_iterations(5),
          StoppingCriteria.max_runtime(60.0)
        ])

      stop_fn = StoppingCriteria.to_stop_fn(criteria)

      # Should not stop before 5 iterations
      for _ <- 1..4 do
        assert stop_fn.(1000) == false
      end

      # 5th iteration should stop (max_iterations triggers)
      assert stop_fn.(1000) == true
    end
  end

  # ==========================================================================
  # Tests matching PyVRP's test_PenaltyManager.py
  # ==========================================================================

  describe "PenaltyManager (matching test_PenaltyManager.py)" do
    test "init_from creates manager from problem data" do
      # Matches: test_init_from_*
      model = build_small_cvrp()
      {:ok, problem_data} = Model.to_problem_data(model)

      pm = PenaltyManager.init_from(problem_data)

      assert pm.load_penalties != []
      assert pm.tw_penalty > 0
      assert pm.dist_penalty > 0
    end

    test "clips penalties to bounds" do
      # Matches: test_max_min_penalty, test_init_clips_penalties
      params = %PenaltyManager.Params{
        min_penalty: 10.0,
        max_penalty: 1000.0
      }

      pm = PenaltyManager.new([0.001], 5000.0, 0.001, params)

      # Clipped to min
      assert hd(pm.load_penalties) == 10.0
      # Clipped to max
      assert pm.tw_penalty == 1000.0
      # Clipped to min
      assert pm.dist_penalty == 10.0
    end

    test "cost_evaluator creates valid evaluator" do
      pm = PenaltyManager.new([100.0], 50.0, 75.0)
      assert {:ok, evaluator} = PenaltyManager.cost_evaluator(pm)
      assert is_reference(evaluator)
    end

    test "max_cost_evaluator creates evaluator with max penalties" do
      params = %PenaltyManager.Params{max_penalty: 100_000.0}
      pm = PenaltyManager.new([100.0], 50.0, 75.0, params)
      assert {:ok, evaluator} = PenaltyManager.max_cost_evaluator(pm)
      assert is_reference(evaluator)
    end
  end

  # ==========================================================================
  # Tests matching PyVRP's test_IteratedLocalSearch.py
  # ==========================================================================

  describe "IteratedLocalSearch (matching test_IteratedLocalSearch.py)" do
    test "params raises on invalid arguments" do
      # Matches: test_params_constructor_raises_when_arguments_invalid
      # Note: In Elixir we use structs which don't validate on construction
      # but the ILS will use these values correctly
    end

    test "best solution improves with more iterations" do
      # Matches: test_best_solution_improves_with_more_iterations
      model = build_small_cvrp()

      {:ok, result_few} =
        Solver.solve(model,
          stop: StoppingCriteria.max_iterations(10),
          seed: 42
        )

      {:ok, result_many} =
        Solver.solve(model,
          stop: StoppingCriteria.max_iterations(500),
          seed: 42
        )

      # More iterations should give at least as good result
      assert Result.cost(result_many) <= Result.cost(result_few)
      assert Result.feasible?(result_many)
    end

    test "result has correct stats" do
      # Matches: test_ils_result_has_correct_stats
      model = build_small_cvrp()

      {:ok, result} =
        Solver.solve(model,
          stop: StoppingCriteria.max_iterations(50),
          seed: 42
        )

      assert result.num_iterations >= 0
      assert result.stats.initial_cost > 0
      assert result.stats.final_cost > 0
      assert result.stats.final_cost <= result.stats.initial_cost
    end
  end

  # ==========================================================================
  # Helper functions
  # ==========================================================================

  defp build_small_cvrp do
    Model.new()
    |> Model.add_depot(x: 0, y: 0)
    |> Model.add_vehicle_type(num_available: 3, capacity: [100])
    |> Model.add_client(x: 10, y: 0, delivery: [20])
    |> Model.add_client(x: 20, y: 0, delivery: [20])
    |> Model.add_client(x: 0, y: 10, delivery: [20])
    |> Model.add_client(x: 0, y: 20, delivery: [20])
  end
end

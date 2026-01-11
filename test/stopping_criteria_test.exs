defmodule ExVrp.StoppingCriteriaTest do
  use ExUnit.Case, async: true

  alias ExVrp.StoppingCriteria

  describe "MaxIterations" do
    test "returns false until max iterations reached" do
      criteria = StoppingCriteria.max_iterations(100)

      # First iteration
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{})
      assert stop? == false

      # Simulate 98 more iterations
      {stop?, criteria} =
        Enum.reduce(2..99, {false, criteria}, fn _, {_, c} ->
          StoppingCriteria.should_stop?(c, %{})
        end)

      assert stop? == false

      # 100th iteration should stop
      {stop?, _criteria} = StoppingCriteria.should_stop?(criteria, %{})
      assert stop? == true
    end

    test "stops immediately when max_iterations is 0" do
      criteria = StoppingCriteria.max_iterations(0)
      {stop?, _criteria} = StoppingCriteria.should_stop?(criteria, %{})
      assert stop? == true
    end
  end

  describe "MaxRuntime" do
    test "returns false while under time limit" do
      # 10 seconds
      criteria = StoppingCriteria.max_runtime(10.0)

      {stop?, _criteria} = StoppingCriteria.should_stop?(criteria, %{})
      assert stop? == false
    end

    test "returns true after time limit exceeded" do
      # 0 seconds - immediate stop
      criteria = StoppingCriteria.max_runtime(0.0)

      # Small sleep to ensure time passes
      Process.sleep(1)

      {stop?, _criteria} = StoppingCriteria.should_stop?(criteria, %{})
      assert stop? == true
    end

    test "raises on negative runtime" do
      assert_raise ArgumentError, fn ->
        StoppingCriteria.max_runtime(-1.0)
      end
    end
  end

  describe "parameter validation" do
    test "raises on negative max_iterations" do
      assert_raise ArgumentError, fn ->
        StoppingCriteria.max_iterations(-1)
      end
    end

    test "raises on negative no_improvement" do
      assert_raise ArgumentError, fn ->
        StoppingCriteria.no_improvement(-1)
      end
    end

    test "raises on empty multiple_criteria" do
      assert_raise ArgumentError, fn ->
        StoppingCriteria.multiple_criteria([])
      end
    end
  end

  describe "NoImprovement" do
    test "returns false while improvements occur" do
      criteria = StoppingCriteria.no_improvement(5)

      # Simulate improvements
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: true})
      assert stop? == false

      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: true})
      assert stop? == false

      {stop?, _criteria} = StoppingCriteria.should_stop?(criteria, %{improved: true})
      assert stop? == false
    end

    test "returns true after max iterations without improvement" do
      criteria = StoppingCriteria.no_improvement(3)

      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false

      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false

      # Third iteration without improvement
      {stop?, _criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == true
    end

    test "resets counter on improvement" do
      criteria = StoppingCriteria.no_improvement(3)

      # Two iterations without improvement
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false

      # Improvement resets counter
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: true})
      assert stop? == false

      # Two more without improvement - should NOT stop (counter was reset)
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false

      # Third without improvement - should stop
      {stop?, _criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == true
    end
  end

  describe "combined criteria" do
    test "stops when any criterion is met (OR)" do
      criteria =
        StoppingCriteria.any([
          StoppingCriteria.max_iterations(5),
          StoppingCriteria.no_improvement(2)
        ])

      # Two iterations without improvement - second criterion triggers
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false

      {stop?, _criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == true
    end

    test "stops when all criteria are met (AND)" do
      criteria =
        StoppingCriteria.all([
          StoppingCriteria.max_iterations(2),
          StoppingCriteria.no_improvement(2)
        ])

      # First iteration without improvement - neither fully met
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false

      # Second iteration without improvement - both met
      {stop?, _criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == true
    end
  end

  describe "to_stop_fn/1" do
    test "creates callable stop function for max_iterations" do
      criteria = StoppingCriteria.max_iterations(5)
      stop_fn = StoppingCriteria.to_stop_fn(criteria)

      # The criterion counts iterations and stops when count >= max
      # With max=5, iterations 1-4 return false, iteration 5 returns true
      # 1st
      assert stop_fn.(1000) == false
      # 2nd
      assert stop_fn.(1000) == false
      # 3rd
      assert stop_fn.(1000) == false
      # 4th
      assert stop_fn.(1000) == false
      # 5th iteration meets the threshold (5 >= 5)
      assert stop_fn.(1000) == true
    end

    test "creates callable stop function for no_improvement" do
      criteria = StoppingCriteria.no_improvement(3)
      stop_fn = StoppingCriteria.to_stop_fn(criteria)

      # First call establishes baseline
      assert stop_fn.(100) == false

      # Improving solutions don't trigger stop
      assert stop_fn.(90) == false
      assert stop_fn.(80) == false
      assert stop_fn.(70) == false

      # Non-improving solutions count towards max
      assert stop_fn.(70) == false
      assert stop_fn.(70) == false
      assert stop_fn.(70) == true
    end

    test "stop function tracks state correctly" do
      criteria = StoppingCriteria.max_iterations(3)
      stop_fn = StoppingCriteria.to_stop_fn(criteria)

      # max_iterations(3) stops on the 3rd call (when count reaches 3)
      # count = 1
      assert stop_fn.(1) == false
      # count = 2
      assert stop_fn.(1) == false
      # count = 3 >= 3
      assert stop_fn.(1) == true
      # count = 4 >= 3
      assert stop_fn.(1) == true
    end
  end

  describe "FirstFeasible" do
    test "returns false for infeasible (:infinity cost)" do
      # The ILS passes :infinity for infeasible solutions (via solution_cost)
      criteria = StoppingCriteria.first_feasible()
      {stop?, _} = StoppingCriteria.should_stop?(criteria, %{best_cost: :infinity})
      assert stop? == false
    end

    test "returns true for feasible (integer cost)" do
      criteria = StoppingCriteria.first_feasible()
      {stop?, _} = StoppingCriteria.should_stop?(criteria, %{best_cost: 1000})
      assert stop? == true
    end
  end

  describe "MaxIterations edge cases" do
    test "stops when count reaches max" do
      # max_iterations(N) stops when the Nth call is made
      # This is because should_stop increments BEFORE checking
      for max <- [2, 5, 10] do
        criteria = StoppingCriteria.max_iterations(max)

        # Should not stop during first (max-1) iterations
        criteria =
          Enum.reduce(1..(max - 1), criteria, fn _, c ->
            {stop?, c} = StoppingCriteria.should_stop?(c, %{})
            assert stop? == false
            c
          end)

        # Max-th iteration should stop (count == max)
        {stop?, _} = StoppingCriteria.should_stop?(criteria, %{})
        assert stop? == true
      end
    end

    test "max_iterations 1 stops immediately" do
      criteria = StoppingCriteria.max_iterations(1)
      # First call: count becomes 1, 1 >= 1, returns true
      {stop?, _} = StoppingCriteria.should_stop?(criteria, %{})
      assert stop? == true
    end

    test "after max iterations stays stopped" do
      criteria = StoppingCriteria.max_iterations(2)

      # First call: count becomes 1, 1 < 2, returns false
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{})
      assert stop? == false
      # Second call: count becomes 2, 2 >= 2, returns true
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{})
      assert stop? == true
      # Third call: count becomes 3, 3 >= 2, returns true
      {stop?, _criteria} = StoppingCriteria.should_stop?(criteria, %{})
      assert stop? == true
    end
  end

  describe "NoImprovement edge cases" do
    test "zero max iterations always stops" do
      criteria = StoppingCriteria.no_improvement(0)
      {stop?, _} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == true
    end

    test "one max iteration behavior" do
      criteria = StoppingCriteria.no_improvement(1)

      # First non-improvement triggers stop (counter goes to 1, 1 >= 1)
      {stop?, _} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == true
    end

    test "n max iterations with mixed improvements" do
      # With n=3, we need 3 consecutive non-improvements to stop
      criteria = StoppingCriteria.no_improvement(3)

      # First k improving iterations (counter stays at 0)
      criteria =
        Enum.reduce(1..2, criteria, fn _, c ->
          {stop?, c} = StoppingCriteria.should_stop?(c, %{improved: true})
          assert stop? == false
          c
        end)

      # Then (n-1) non-improving iterations (counter goes to 1, then 2)
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false

      # Third non-improving (counter goes to 3, 3 >= 3)
      {stop?, _} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == true
    end

    test "improvement resets counter completely" do
      criteria = StoppingCriteria.no_improvement(3)

      # Two non-improving (counter at 2)
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false

      # Improve resets (counter to 0)
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: true})
      assert stop? == false

      # Need full 3 non-improving again
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false
      {stop?, _} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == true
    end
  end

  describe "MultipleCriteria" do
    test "combines max_iterations and max_runtime" do
      criteria =
        StoppingCriteria.multiple_criteria([
          StoppingCriteria.max_iterations(5),
          StoppingCriteria.max_runtime(10.0)
        ])

      # Should not stop immediately
      {stop?, _} = StoppingCriteria.should_stop?(criteria, %{})
      assert stop? == false
    end

    test "three criteria combined" do
      criteria =
        StoppingCriteria.any([
          StoppingCriteria.max_iterations(10),
          StoppingCriteria.max_runtime(10.0),
          StoppingCriteria.no_improvement(3)
        ])

      # Should not stop immediately
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false

      # After 3 non-improving, should stop
      {stop?, criteria} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == false
      {stop?, _} = StoppingCriteria.should_stop?(criteria, %{improved: false})
      assert stop? == true
    end

    test "nested criteria" do
      inner =
        StoppingCriteria.any([
          StoppingCriteria.max_iterations(5),
          StoppingCriteria.no_improvement(2)
        ])

      outer =
        StoppingCriteria.any([
          inner,
          StoppingCriteria.max_runtime(10.0)
        ])

      # After 2 non-improving, inner should trigger
      {stop?, outer} = StoppingCriteria.should_stop?(outer, %{improved: false})
      assert stop? == false
      {stop?, _} = StoppingCriteria.should_stop?(outer, %{improved: false})
      assert stop? == true
    end
  end
end

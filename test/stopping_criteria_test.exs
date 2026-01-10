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
end

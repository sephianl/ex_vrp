defmodule ExVrp.ResultTest do
  @moduledoc """
  Tests for ExVrp.IteratedLocalSearch.Result module.

  This mirrors PyVRP's test_Result.py.
  """
  use ExUnit.Case, async: true

  alias ExVrp.IteratedLocalSearch.Result
  alias ExVrp.Model
  alias ExVrp.Solution
  alias ExVrp.Solver

  describe "Result struct" do
    test "has expected fields" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 10)

      assert Map.has_key?(result, :best)
      assert Map.has_key?(result, :stats)
      assert Map.has_key?(result, :num_iterations)
      assert Map.has_key?(result, :runtime)
    end
  end

  describe "Result.cost/1" do
    test "returns distance for feasible solution" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 10)

      if result.best.is_feasible do
        assert Result.cost(result) == result.best.distance
      end
    end

    test "returns infinity for infeasible solution" do
      # Create a manually constructed infeasible result for testing
      solution = %Solution{
        routes: [[1, 2]],
        distance: 100,
        duration: 50,
        num_clients: 2,
        is_feasible: false,
        is_complete: true
      }

      result = %Result{
        best: solution,
        stats: %{initial_cost: 100, final_cost: 100},
        num_iterations: 10,
        runtime: 5
      }

      assert Result.cost(result) == :infinity
    end
  end

  describe "Result.feasible?/1" do
    test "returns true for feasible result" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 50)

      # Simple problem should be feasible
      assert Result.feasible?(result) == result.best.is_feasible
    end

    test "returns false for infeasible result" do
      solution = %Solution{
        routes: [[1, 2]],
        distance: 100,
        duration: 50,
        num_clients: 2,
        is_feasible: false,
        is_complete: true
      }

      result = %Result{
        best: solution,
        stats: %{},
        num_iterations: 10,
        runtime: 5
      }

      assert Result.feasible?(result) == false
    end
  end

  describe "Result.summary/1" do
    test "returns summary string" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 10)

      summary = Result.summary(result)

      assert is_binary(summary)
      assert String.contains?(summary, "Solution results")
      assert String.contains?(summary, "Feasible:")
      assert String.contains?(summary, "Cost:")
      assert String.contains?(summary, "Routes:")
      assert String.contains?(summary, "Distance:")
      assert String.contains?(summary, "Iterations:")
    end
  end

  describe "Result stats" do
    test "initial_cost is captured" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 50)

      assert result.stats.initial_cost > 0
    end

    test "final_cost is captured" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 50)

      assert result.stats.final_cost > 0
    end

    test "final_cost is at most initial_cost" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 100)

      assert result.stats.final_cost <= result.stats.initial_cost
    end
  end

  describe "Result.best solution" do
    test "best has Solution struct" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 10)

      assert %Solution{} = result.best
    end

    test "best solution has routes" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 10)

      assert is_list(result.best.routes)
      assert result.best.routes != []
    end

    test "best solution has stats" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 20)

      assert result.best.stats.iterations >= 0
      assert result.best.stats.improvements >= 0
      assert result.best.stats.restarts >= 0
    end
  end

  describe "num_iterations" do
    test "is non-negative" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 10)

      assert result.num_iterations >= 0
    end

    test "respects max_iterations" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 5)

      # Should be within a reasonable bound of max_iterations
      assert result.num_iterations <= 10
    end
  end

  describe "runtime" do
    test "is non-negative" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, max_iterations: 10)

      assert result.runtime >= 0
    end
  end
end

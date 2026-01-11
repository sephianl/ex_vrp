defmodule ExVrp.CostEvaluatorTest do
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  @moduletag :nif_required

  describe "create_cost_evaluator/1" do
    test "creates evaluator with default penalties" do
      assert {:ok, evaluator} =
               Native.create_cost_evaluator(
                 load_penalties: [1.0],
                 tw_penalty: 1.0,
                 dist_penalty: 1.0
               )

      assert is_reference(evaluator)
    end

    test "creates evaluator with high penalties" do
      assert {:ok, evaluator} =
               Native.create_cost_evaluator(
                 load_penalties: [1000.0],
                 tw_penalty: 1000.0,
                 dist_penalty: 1000.0
               )

      assert is_reference(evaluator)
    end

    test "creates evaluator with multiple load dimensions" do
      assert {:ok, evaluator} =
               Native.create_cost_evaluator(
                 load_penalties: [100.0, 200.0, 300.0],
                 tw_penalty: 50.0,
                 dist_penalty: 50.0
               )

      assert is_reference(evaluator)
    end

    test "raises for negative penalties" do
      assert_raise RuntimeError, ~r/negative/i, fn ->
        Native.create_cost_evaluator(
          load_penalties: [-1.0],
          tw_penalty: 1.0,
          dist_penalty: 1.0
        )
      end
    end
  end

  describe "solution_penalised_cost/2" do
    test "returns cost for feasible solution" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [100.0],
          tw_penalty: 100.0,
          dist_penalty: 100.0
        )

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)
      cost = Native.solution_penalised_cost(solution, cost_evaluator)

      assert is_integer(cost)
      assert cost >= 0
    end

    test "penalises capacity violations" do
      # Model where capacity is exceeded
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        # Exceeds capacity
        |> Model.add_client(x: 10, y: 0, delivery: [20])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, low_penalty_eval} =
        Native.create_cost_evaluator(
          load_penalties: [1.0],
          tw_penalty: 1.0,
          dist_penalty: 1.0
        )

      {:ok, high_penalty_eval} =
        Native.create_cost_evaluator(
          load_penalties: [1000.0],
          tw_penalty: 1.0,
          dist_penalty: 1.0
        )

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      low_cost = Native.solution_penalised_cost(solution, low_penalty_eval)
      high_cost = Native.solution_penalised_cost(solution, high_penalty_eval)

      # Higher penalty should result in higher cost for infeasible solution
      assert high_cost > low_cost
    end
  end

  describe "solution_cost/2" do
    test "returns infinity for infeasible solution" do
      # Model where capacity must be exceeded
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        # Exceeds capacity
        |> Model.add_client(x: 10, y: 0, delivery: [50])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [100.0],
          tw_penalty: 100.0,
          dist_penalty: 100.0
        )

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      # If solution is infeasible, cost should be very large
      if not Native.solution_is_feasible(solution) do
        cost = Native.solution_cost(solution, cost_evaluator)
        # Cost should be maximum value for infeasible
        assert cost == :infinity or cost > 1_000_000_000
      end
    end

    test "returns actual cost for feasible solution" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 3, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 0, y: 10, delivery: [10])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [100.0],
          tw_penalty: 100.0,
          dist_penalty: 100.0
        )

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      if Native.solution_is_feasible(solution) do
        cost = Native.solution_cost(solution, cost_evaluator)
        penalised = Native.solution_penalised_cost(solution, cost_evaluator)

        # For feasible solutions, cost should equal penalised cost
        assert cost == penalised
      end
    end
  end

  describe "cost_evaluator with time window penalties" do
    test "penalises time window violations" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        # Very tight time window
        |> Model.add_client(x: 100, y: 0, delivery: [10], tw_early: 0, tw_late: 10)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], tw_early: 0, tw_late: 1000)

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, low_tw_eval} =
        Native.create_cost_evaluator(
          load_penalties: [1.0],
          tw_penalty: 1.0,
          dist_penalty: 1.0
        )

      {:ok, high_tw_eval} =
        Native.create_cost_evaluator(
          load_penalties: [1.0],
          tw_penalty: 1000.0,
          dist_penalty: 1.0
        )

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      # If there's time warp, higher penalty should result in higher cost
      if not Native.solution_is_feasible(solution) do
        low_cost = Native.solution_penalised_cost(solution, low_tw_eval)
        high_cost = Native.solution_penalised_cost(solution, high_tw_eval)
        assert high_cost > low_cost
      end
    end
  end

  describe "cost_evaluator with distance constraints" do
    test "penalises distance violations" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1000, y: 0, delivery: [10])
        |> Model.add_client(x: 0, y: 1000, delivery: [10])
        # Very low max_distance to trigger violations
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], max_distance: 100)

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, low_dist_eval} =
        Native.create_cost_evaluator(
          load_penalties: [1.0],
          tw_penalty: 1.0,
          dist_penalty: 1.0
        )

      {:ok, high_dist_eval} =
        Native.create_cost_evaluator(
          load_penalties: [1.0],
          tw_penalty: 1.0,
          dist_penalty: 1000.0
        )

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      low_cost = Native.solution_penalised_cost(solution, low_dist_eval)
      high_cost = Native.solution_penalised_cost(solution, high_dist_eval)

      # Higher distance penalty should result in higher cost
      assert high_cost >= low_cost
    end
  end

  describe "cost_evaluator with multiple load dimensions" do
    test "handles multi-dimensional load penalties" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [30, 20], pickup: [0, 0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [20, 10])

      {:ok, problem_data} = Model.to_problem_data(model)

      # Penalties for both dimensions
      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [100.0, 200.0],
          tw_penalty: 1.0,
          dist_penalty: 1.0
        )

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)
      cost = Native.solution_penalised_cost(solution, cost_evaluator)

      # Cost should reflect violations in both dimensions
      assert cost > 0
    end

    test "different dimension penalties affect cost differently" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [30, 30], pickup: [0, 0])
        # Capacity exceeded in both dimensions
        |> Model.add_vehicle_type(num_available: 1, capacity: [20, 20])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, eval1} =
        Native.create_cost_evaluator(
          load_penalties: [100.0, 100.0],
          tw_penalty: 1.0,
          dist_penalty: 1.0
        )

      {:ok, eval2} =
        Native.create_cost_evaluator(
          load_penalties: [100.0, 500.0],
          tw_penalty: 1.0,
          dist_penalty: 1.0
        )

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      cost1 = Native.solution_penalised_cost(solution, eval1)
      cost2 = Native.solution_penalised_cost(solution, eval2)

      # Higher second dimension penalty should result in higher cost
      assert cost2 > cost1
    end
  end

  describe "cost_evaluator with zero penalties" do
    test "zero penalties result in base cost only" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, zero_penalty_eval} =
        Native.create_cost_evaluator(
          load_penalties: [0.0],
          tw_penalty: 0.0,
          dist_penalty: 0.0
        )

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)
      cost = Native.solution_penalised_cost(solution, zero_penalty_eval)

      # With zero penalties, cost should be just the distance
      distance = Native.solution_distance(solution)
      assert cost == distance
    end
  end

  describe "cost_evaluator edge cases" do
    test "single dimension penalty" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [100.0],
          tw_penalty: 100.0,
          dist_penalty: 100.0
        )

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)
      cost = Native.solution_penalised_cost(solution, cost_evaluator)

      assert is_integer(cost)
      assert cost >= 0
    end

    test "very high penalties" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [1_000_000.0],
          tw_penalty: 1_000_000.0,
          dist_penalty: 1_000_000.0
        )

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)
      cost = Native.solution_penalised_cost(solution, cost_evaluator)

      assert is_integer(cost)
    end
  end
end

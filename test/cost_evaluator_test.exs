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
end

defmodule ExVrp.LocalSearchTest do
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  @moduletag :nif_required

  describe "local_search/3" do
    test "improves a random solution" do
      model = build_cvrp_model(10)

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [100.0],
          tw_penalty: 100.0,
          dist_penalty: 100.0
        )

      # Create a random solution
      {:ok, initial_solution} = Native.create_random_solution(problem_data, seed: 42)
      initial_cost = Native.solution_penalised_cost(initial_solution, cost_evaluator)

      # Run local search
      {:ok, improved_solution} =
        Native.local_search(
          initial_solution,
          problem_data,
          cost_evaluator
        )

      improved_cost = Native.solution_penalised_cost(improved_solution, cost_evaluator)

      # Local search should not make the solution worse
      assert improved_cost <= initial_cost
    end

    test "returns feasible solution when possible" do
      model = build_cvrp_model(5)

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [100.0],
          tw_penalty: 100.0,
          dist_penalty: 100.0
        )

      {:ok, initial_solution} = Native.create_random_solution(problem_data, seed: 42)

      {:ok, improved_solution} =
        Native.local_search(
          initial_solution,
          problem_data,
          cost_evaluator
        )

      # Small problem should be solvable to feasibility
      assert Native.solution_is_feasible(improved_solution)
    end

    test "preserves completeness" do
      model = build_cvrp_model(5)

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [100.0],
          tw_penalty: 100.0,
          dist_penalty: 100.0
        )

      {:ok, initial_solution} = Native.create_random_solution(problem_data, seed: 42)

      {:ok, improved_solution} =
        Native.local_search(
          initial_solution,
          problem_data,
          cost_evaluator
        )

      # All required clients should still be visited
      assert Native.solution_is_complete(improved_solution)
    end

    test "reduces distance on larger problems" do
      model = build_cvrp_model(20)

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [100.0],
          tw_penalty: 100.0,
          dist_penalty: 100.0
        )

      {:ok, initial_solution} = Native.create_random_solution(problem_data, seed: 123)
      initial_distance = Native.solution_distance(initial_solution)

      {:ok, improved_solution} =
        Native.local_search(
          initial_solution,
          problem_data,
          cost_evaluator
        )

      improved_distance = Native.solution_distance(improved_solution)

      # On larger problems, local search should typically improve distance
      # (may not always improve if initial solution is lucky)
      assert improved_distance <= initial_distance
    end
  end

  describe "local_search/3 with options" do
    test "supports exhaustive search" do
      model = build_cvrp_model(8)

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [100.0],
          tw_penalty: 100.0,
          dist_penalty: 100.0
        )

      {:ok, initial_solution} = Native.create_random_solution(problem_data, seed: 42)

      # Non-exhaustive
      {:ok, solution1} =
        Native.local_search(
          initial_solution,
          problem_data,
          cost_evaluator,
          exhaustive: false
        )

      # Exhaustive should be at least as good (possibly better)
      {:ok, solution2} =
        Native.local_search(
          initial_solution,
          problem_data,
          cost_evaluator,
          exhaustive: true
        )

      cost1 = Native.solution_penalised_cost(solution1, cost_evaluator)
      cost2 = Native.solution_penalised_cost(solution2, cost_evaluator)

      assert cost2 <= cost1
    end
  end

  # Helper to build a CVRP model with n clients
  defp build_cvrp_model(n) do
    model =
      Model.new()
      |> Model.add_depot(x: 50, y: 50)
      |> Model.add_vehicle_type(num_available: div(n, 3) + 1, capacity: [100])

    # Add clients in a rough circle around the depot
    Enum.reduce(1..n, model, fn i, model ->
      angle = 2 * :math.pi() * i / n
      x = round(50 + 40 * :math.cos(angle))
      y = round(50 + 40 * :math.sin(angle))
      demand = :rand.uniform(20) + 5

      Model.add_client(model, x: x, y: y, delivery: [demand])
    end)
  end
end

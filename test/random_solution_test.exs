defmodule ExVrp.RandomSolutionTest do
  @moduledoc """
  Tests for random solution generation.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  @moduletag :nif_required

  describe "create_random_solution/2" do
    test "creates valid solution" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      assert is_reference(solution)
    end

    test "solution is complete" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      assert Native.solution_is_complete(solution)
    end

    test "respects seed for reproducibility" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_client(x: 30, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 3, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, sol1} = Native.create_random_solution(problem_data, seed: 123)
      {:ok, sol2} = Native.create_random_solution(problem_data, seed: 123)

      # Same seed should produce identical results
      assert Native.solution_distance(sol1) == Native.solution_distance(sol2)
      assert Native.solution_routes(sol1) == Native.solution_routes(sol2)
    end

    test "different seeds produce different solutions" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_client(x: 30, y: 0, delivery: [10])
        |> Model.add_client(x: 40, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 4, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, sol1} = Native.create_random_solution(problem_data, seed: 1)
      {:ok, sol2} = Native.create_random_solution(problem_data, seed: 2)

      # Different seeds should usually produce different solutions
      routes1 = Native.solution_routes(sol1)
      routes2 = Native.solution_routes(sol2)
      assert routes1 != routes2
    end

    test "assigns all clients" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_client(x: 30, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 3, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      routes = Native.solution_routes(solution)
      all_clients = routes |> List.flatten() |> Enum.sort()

      # Clients are 1, 2, 3 (0 is depot)
      assert all_clients == [1, 2, 3]
    end
  end

  describe "create_random_solution/2 with constraints" do
    test "handles capacity constraints" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [60])
        |> Model.add_client(x: 20, y: 0, delivery: [60])
        # Capacity forces clients into separate routes
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      # Solution should be complete even with tight capacity
      assert Native.solution_is_complete(solution)
    end

    test "handles time windows" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], tw_early: 0, tw_late: 100)
        |> Model.add_client(x: 20, y: 0, delivery: [10], tw_early: 50, tw_late: 200)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100], tw_early: 0, tw_late: 300)

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      assert Native.solution_is_complete(solution)
    end

    test "handles multiple vehicle types" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      assert Native.solution_is_complete(solution)
    end
  end

  describe "create_random_solution/2 edge cases" do
    test "single client" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      assert Native.solution_is_complete(solution)
      routes = Native.solution_routes(solution)
      assert length(routes) == 1
      assert hd(routes) == [1]
    end

    test "many clients" do
      model =
        Model.new()
        |> Model.add_depot(x: 50, y: 50)
        |> Model.add_vehicle_type(num_available: 20, capacity: [100])

      # Add 50 clients
      model =
        Enum.reduce(1..50, model, fn i, m ->
          angle = 2 * :math.pi() * i / 50
          x = round(50 + 40 * :math.cos(angle))
          y = round(50 + 40 * :math.sin(angle))
          Model.add_client(m, x: x, y: y, delivery: [5])
        end)

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      assert Native.solution_is_complete(solution)
    end

    test "multi-depot" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 100, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 90, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      assert Native.solution_is_complete(solution)
    end

    test "multi-dimensional capacity" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10, 5], pickup: [0, 0])
        |> Model.add_client(x: 20, y: 0, delivery: [15, 10], pickup: [0, 0])
        |> Model.add_vehicle_type(num_available: 2, capacity: [50, 30])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      assert Native.solution_is_complete(solution)
    end
  end

  describe "solution statistics" do
    test "returns correct number of clients" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_client(x: 30, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 3, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      assert Native.solution_num_clients(solution) == 3
    end

    test "distance is positive" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      assert Native.solution_distance(solution) > 0
    end

    test "duration is non-negative" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], service_duration: 10)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      assert Native.solution_duration(solution) >= 0
    end
  end
end

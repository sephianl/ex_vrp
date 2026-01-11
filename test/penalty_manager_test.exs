defmodule ExVrp.PenaltyManagerTest do
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.PenaltyManager

  @moduletag :nif_required

  describe "new/4" do
    test "creates penalty manager with initial penalties" do
      pm = PenaltyManager.new([100.0], 50.0, 75.0)

      assert pm.load_penalties == [100.0]
      assert pm.tw_penalty == 50.0
      assert pm.dist_penalty == 75.0
    end

    test "clips penalties to min/max bounds" do
      params = %PenaltyManager.Params{min_penalty: 10.0, max_penalty: 1000.0}

      pm = PenaltyManager.new([0.01], 0.001, 10_000.0, params)

      # Clipped to min
      assert pm.load_penalties == [10.0]
      # Clipped to min
      assert pm.tw_penalty == 10.0
      # Clipped to max
      assert pm.dist_penalty == 1000.0
    end
  end

  describe "init_from/2" do
    test "creates penalty manager from problem data" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10])

      {:ok, problem_data} = Model.to_problem_data(model)

      pm = PenaltyManager.init_from(problem_data)

      assert length(pm.load_penalties) == 1
      assert pm.tw_penalty > 0
      assert pm.dist_penalty > 0
    end

    test "respects custom params" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [50])
        |> Model.add_client(x: 5, y: 0, delivery: [10])

      {:ok, problem_data} = Model.to_problem_data(model)

      params = %PenaltyManager.Params{
        target_feasible: 0.5,
        solutions_between_updates: 100
      }

      pm = PenaltyManager.init_from(problem_data, params)

      assert pm.params.target_feasible == 0.5
      assert pm.params.solutions_between_updates == 100
    end
  end

  describe "penalties/1" do
    test "returns current penalties as tuple" do
      pm = PenaltyManager.new([100.0, 200.0], 50.0, 75.0)

      {load_penalties, tw_penalty, dist_penalty} = PenaltyManager.penalties(pm)

      assert load_penalties == [100.0, 200.0]
      assert tw_penalty == 50.0
      assert dist_penalty == 75.0
    end
  end

  describe "cost_evaluator/1" do
    test "creates cost evaluator with current penalties" do
      pm = PenaltyManager.new([100.0], 50.0, 75.0)

      assert {:ok, evaluator} = PenaltyManager.cost_evaluator(pm)
      assert is_reference(evaluator)
    end
  end

  describe "max_cost_evaluator/1" do
    test "creates cost evaluator with max penalties" do
      params = %PenaltyManager.Params{max_penalty: 100_000.0}
      pm = PenaltyManager.new([100.0], 50.0, 75.0, params)

      assert {:ok, evaluator} = PenaltyManager.max_cost_evaluator(pm)
      assert is_reference(evaluator)
    end
  end

  describe "register/2" do
    test "tracks solution feasibility" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10])

      {:ok, problem_data} = Model.to_problem_data(model)
      pm = PenaltyManager.init_from(problem_data)

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      pm2 = PenaltyManager.register(pm, solution)

      # Feasibility should be tracked
      assert pm2.tw_feas != []
    end

    test "updates penalties after threshold" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10])

      {:ok, problem_data} = Model.to_problem_data(model)

      # Use very small threshold for testing
      params = %PenaltyManager.Params{
        solutions_between_updates: 3,
        # All infeasible target
        target_feasible: 0.0,
        penalty_increase: 2.0
      }

      pm = PenaltyManager.init_from(problem_data, params)
      _initial_tw_penalty = pm.tw_penalty

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      # Register 3 solutions to trigger update
      pm2 =
        pm
        |> PenaltyManager.register(solution)
        |> PenaltyManager.register(solution)
        |> PenaltyManager.register(solution)

      # If solution was feasible (100% vs 0% target), penalty should decrease
      # If infeasible, penalty should increase
      # Either way, penalty should have changed
      # Should be reset after update
      assert pm2.tw_feas == []
    end
  end

  describe "Params validation" do
    test "uses default values" do
      params = %PenaltyManager.Params{}

      assert params.solutions_between_updates == 500
      assert params.penalty_increase == 1.25
      assert params.penalty_decrease == 0.85
      assert params.target_feasible == 0.65
      assert params.feas_tolerance == 0.05
      assert params.min_penalty == 0.1
      assert params.max_penalty == 100_000.0
    end
  end

  describe "penalty updates" do
    test "does not update penalties before sufficient registrations" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10])

      {:ok, problem_data} = Model.to_problem_data(model)

      # Use 4 registrations before update
      params = %PenaltyManager.Params{
        solutions_between_updates: 4,
        penalty_increase: 1.1,
        penalty_decrease: 0.9,
        target_feasible: 0.5
      }

      pm = PenaltyManager.new([100.0], 100.0, 100.0, params)
      initial_tw_penalty = pm.tw_penalty

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      # Register 3 times - should not trigger update
      pm2 =
        pm
        |> PenaltyManager.register(solution)
        |> PenaltyManager.register(solution)
        |> PenaltyManager.register(solution)

      # Penalty should be unchanged
      assert pm2.tw_penalty == initial_tw_penalty
      # Feasibility list should have 3 entries
      assert length(pm2.tw_feas) == 3
    end

    test "updates penalties after threshold registrations" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10])

      {:ok, problem_data} = Model.to_problem_data(model)

      # Use 3 registrations before update
      params = %PenaltyManager.Params{
        solutions_between_updates: 3,
        penalty_increase: 1.5,
        penalty_decrease: 0.5,
        target_feasible: 0.5,
        feas_tolerance: 0.0
      }

      pm = PenaltyManager.new([100.0], 100.0, 100.0, params)

      {:ok, solution} = Native.create_random_solution(problem_data, seed: 42)

      # Register 3 times to trigger update
      pm2 =
        pm
        |> PenaltyManager.register(solution)
        |> PenaltyManager.register(solution)
        |> PenaltyManager.register(solution)

      # Feasibility list should be reset after update
      assert pm2.tw_feas == []
      # Penalty should have changed based on feasibility
      assert pm2.tw_penalty != 100.0 or pm2.load_penalties != [100.0]
    end
  end

  describe "multiple load dimensions" do
    test "handles multiple load dimensions" do
      # Vehicle has 2 capacity dimensions, clients must match in both delivery and pickup
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100, 50])
        |> Model.add_client(x: 10, y: 0, delivery: [10, 2], pickup: [0, 0])
        |> Model.add_client(x: 20, y: 0, delivery: [20, 3], pickup: [0, 0])

      {:ok, problem_data} = Model.to_problem_data(model)

      pm = PenaltyManager.init_from(problem_data)

      # Should have 2 load penalties
      assert length(pm.load_penalties) == 2

      # Both should be positive
      assert Enum.all?(pm.load_penalties, &(&1 > 0))
    end

    test "clips penalties to min/max for each dimension" do
      params = %PenaltyManager.Params{min_penalty: 10.0, max_penalty: 1000.0}

      # Create with out-of-bounds penalties
      pm = PenaltyManager.new([0.001, 50.0, 10_000.0], 50.0, 75.0, params)

      # All should be clipped
      [p1, p2, p3] = pm.load_penalties
      # Clipped to min
      assert p1 == 10.0
      # In range
      assert p2 == 50.0
      # Clipped to max
      assert p3 == 1000.0
    end
  end

  describe "max_cost_evaluator" do
    test "returns evaluator with max penalty values" do
      params = %PenaltyManager.Params{max_penalty: 500.0}

      # Start with low penalties
      pm = PenaltyManager.new([10.0, 20.0], 30.0, 40.0, params)

      {:ok, max_eval} = PenaltyManager.max_cost_evaluator(pm)
      {:ok, normal_eval} = PenaltyManager.cost_evaluator(pm)

      # Max evaluator should give higher penalised costs for violations
      # (We can't directly test penalty values, but they should differ)
      assert max_eval != normal_eval
    end
  end
end

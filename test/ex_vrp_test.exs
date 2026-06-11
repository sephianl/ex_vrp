defmodule ExVrpTest do
  use ExUnit.Case, async: true

  alias ExVrp.Model

  describe "solve/2" do
    @tag :nif_required
    test "solves a simple CVRP" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])
        |> Model.add_client(x: 2, y: 2, delivery: [20])
        |> Model.add_client(x: 3, y: 1, delivery: [15])

      assert {:ok, result} = ExVrp.solve(model, max_iterations: 100)
      assert result.best.is_feasible
      assert result.best.is_complete
      assert result.best.routes != []
    end

    @tag :nif_required
    test "respects max_iterations option" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])

      # Should complete quickly with low iterations
      assert {:ok, _result} = ExVrp.solve(model, max_iterations: 10)
    end

    @tag :nif_required
    @tag :nif_required
    test "warm-starts from :initial_routes assigning routes by vehicle type index" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])
        |> Model.add_client(x: 2, y: 2, delivery: [10])
        |> Model.add_client(x: 3, y: 1, delivery: [10])
        |> Model.add_client(x: 4, y: 2, delivery: [10])

      assert {:ok, result} =
               ExVrp.solve(model,
                 initial_routes: [[1, 2], [], [3, 4]],
                 max_iterations: 1,
                 num_starts: 1,
                 seed: 1
               )

      assert result.best.is_feasible
      assert length(result.best.routes) == 2
    end

    @tag :nif_required
    test "falls back to empty start when :initial_routes references unknown client" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])

      assert {:ok, result} =
               ExVrp.solve(model,
                 initial_routes: [[99]],
                 max_iterations: 10,
                 num_starts: 1,
                 seed: 1
               )

      assert result.best.is_feasible
    end

    @tag :nif_required
    test "falls back to empty start when :initial_routes has more lists than vehicle types" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])
        |> Model.add_client(x: 2, y: 2, delivery: [10])

      assert {:ok, result} =
               ExVrp.solve(model,
                 initial_routes: [[1], [2]],
                 max_iterations: 10,
                 num_starts: 1,
                 seed: 1
               )

      assert result.best.is_feasible
    end

    @tag :nif_required
    test "falls back to empty start when :initial_routes contains duplicate clients" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])
        |> Model.add_client(x: 2, y: 2, delivery: [10])

      assert {:ok, result} =
               ExVrp.solve(model,
                 initial_routes: [[1], [1]],
                 max_iterations: 10,
                 num_starts: 1,
                 seed: 1
               )

      assert result.best.is_feasible
    end

    @tag :nif_required
    test "accepts capacity-infeasible :initial_routes (solver can repair)" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [80])
        |> Model.add_client(x: 2, y: 2, delivery: [80])

      assert {:ok, result} =
               ExVrp.solve(model,
                 initial_routes: [[1, 2]],
                 max_iterations: 100,
                 num_starts: 1,
                 seed: 1
               )

      assert result.best.is_feasible
    end

    @tag :nif_required
    test "accepts time-window-infeasible :initial_routes (solver can repair)" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], time_windows: [{0, 1000}])
        |> Model.add_client(x: 100, y: 0, delivery: [10], tw_early: 0, tw_late: 5)

      assert {:ok, result} =
               ExVrp.solve(model,
                 initial_routes: [[1]],
                 max_iterations: 100,
                 num_starts: 1,
                 seed: 1
               )

      assert is_map(result.best)
    end

    @tag :nif_required
    test "warm-start skips empty inner lists" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])
        |> Model.add_client(x: 2, y: 2, delivery: [10])

      assert {:ok, result} =
               ExVrp.solve(model,
                 initial_routes: [[], [1, 2]],
                 max_iterations: 1,
                 num_starts: 1,
                 seed: 1
               )

      assert result.best.is_feasible
      assert length(result.best.routes) == 1
    end

    test "respects seed for reproducibility" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])
        |> Model.add_client(x: 2, y: 2, delivery: [20])

      {:ok, result1} = ExVrp.solve(model, seed: 42, max_iterations: 100)
      {:ok, result2} = ExVrp.solve(model, seed: 42, max_iterations: 100)

      # Same seed should give same result
      assert result1.best.routes == result2.best.routes
    end
  end

  describe "solve!/2" do
    @tag :nif_required
    test "returns solution directly on success" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])

      result = ExVrp.solve!(model, max_iterations: 10)
      assert result.best.is_feasible
    end

    @tag :nif_required
    test "raises SolveError on validation failure" do
      # Model with no depot should fail validation
      model =
        Model.new()
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])

      assert_raise ExVrp.SolveError, fn ->
        ExVrp.solve!(model, max_iterations: 10)
      end
    end
  end
end

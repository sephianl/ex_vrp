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
end

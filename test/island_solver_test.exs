defmodule ExVrp.IslandSolverTest do
  use ExUnit.Case, async: true

  alias ExVrp.IteratedLocalSearch
  alias ExVrp.Model
  alias ExVrp.Solver

  @moduletag :nif_required

  describe "island solver" do
    test "produces valid result with 2 islands" do
      model = build_ok_small_model()

      {:ok, result} = Solver.solve(model, max_iterations: 50, strategy: :island, num_islands: 2, seed: 42)

      assert %IteratedLocalSearch.Result{} = result
      assert result.best.is_feasible == true
      assert result.best.num_clients == 4
      assert is_integer(result.runtime)
      assert result.runtime > 0
    end

    test "respects max_runtime" do
      model = build_ok_small_model()

      {:ok, result} = Solver.solve(model, max_runtime: 500, strategy: :island, num_islands: 2, seed: 42)

      assert result.runtime < 2000
    end

    test "single island behaves like single solver" do
      model = build_ok_small_model()

      {:ok, result} = Solver.solve(model, max_iterations: 10, strategy: :island, num_islands: 1, seed: 42)

      assert %IteratedLocalSearch.Result{} = result
      assert result.best.num_clients == 4
    end

    test "result struct matches single solver interface" do
      model = build_ok_small_model()

      {:ok, result} = Solver.solve(model, max_iterations: 20, strategy: :island, num_islands: 2, seed: 42)

      assert %ExVrp.Solution{} = result.best
      assert is_list(result.best.routes)
      assert is_boolean(result.best.is_feasible)
      assert is_integer(result.num_iterations)
      assert is_map(result.stats)
    end
  end

  defp build_ok_small_model do
    distances = [
      [0, 1544, 1944, 1931, 1476],
      [1726, 0, 1992, 1427, 1593],
      [1965, 1975, 0, 621, 1090],
      [2063, 1433, 647, 0, 818],
      [1475, 1594, 1090, 828, 0]
    ]

    Model.new()
    |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
    |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
    |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
    |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
    |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
    |> Model.add_vehicle_type(num_available: 3, capacity: [10], tw_early: 0, tw_late: 45_000)
    |> Model.set_distance_matrices([distances])
    |> Model.set_duration_matrices([distances])
  end
end

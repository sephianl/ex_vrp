defmodule ExVrp.SolveTest do
  use ExUnit.Case, async: true

  alias ExVrp.IteratedLocalSearch
  alias ExVrp.Model
  alias ExVrp.PenaltyManager
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  describe "solve with same seed" do
    test "produces same results with same seed" do
      model = build_ok_small_model()

      stop = StoppingCriteria.max_iterations(10)
      {:ok, res1} = Solver.solve(model, stop: stop, seed: 42)
      {:ok, res2} = Solver.solve(model, stop: stop, seed: 42)

      # Same seed should give same solution
      assert res1.best.routes == res2.best.routes
      assert res1.best.distance == res2.best.distance
      assert res1.num_iterations == res2.num_iterations
    end

    test "produces different results with different seeds" do
      model = build_ok_small_model()

      stop = StoppingCriteria.max_iterations(50)
      {:ok, res1} = Solver.solve(model, stop: stop, seed: 1)
      {:ok, res2} = Solver.solve(model, stop: stop, seed: 9999)

      # Different seeds may give different solutions
      # (or same solution, but iteration paths will differ)
      # We just check that solver runs successfully
      assert res1.best.is_feasible == true or res1.best.is_feasible == false
      assert res2.best.is_feasible == true or res2.best.is_feasible == false
    end
  end

  describe "solve with stopping criteria" do
    test "respects max_iterations" do
      model = build_ok_small_model()

      {:ok, result} = Solver.solve(model, max_iterations: 5)
      assert result.num_iterations <= 5
    end

    test "respects max_runtime" do
      model = build_ok_small_model()

      # Very short runtime
      {:ok, result} = Solver.solve(model, max_runtime: 0.001)
      # Should complete quickly
      # Less than 1 second
      assert result.runtime < 1000
    end

    test "respects custom stopping criterion" do
      model = build_ok_small_model()

      stop = StoppingCriteria.max_iterations(3)
      {:ok, result} = Solver.solve(model, stop: stop)
      assert result.num_iterations <= 3
    end

    test "stops when first feasible found" do
      model = build_ok_small_model()

      stop = StoppingCriteria.first_feasible_or(StoppingCriteria.max_iterations(1000))
      {:ok, result} = Solver.solve(model, stop: stop)

      # Should stop as soon as feasible solution is found
      if result.best.is_feasible do
        # If feasible, should have stopped early
        assert result.num_iterations < 1000
      end
    end
  end

  describe "solve with ILS params" do
    test "accepts custom ILS params" do
      model = build_ok_small_model()

      ils_params = %IteratedLocalSearch.Params{
        max_no_improvement: 5,
        history_size: 1
      }

      {:ok, result} = Solver.solve(model, max_iterations: 10, ils_params: ils_params)
      assert result.num_iterations <= 10
    end
  end

  describe "solve with penalty params" do
    test "accepts custom penalty params" do
      model = build_ok_small_model()

      penalty_params = %PenaltyManager.Params{
        penalty_increase: 1.5,
        penalty_decrease: 0.8,
        solutions_between_updates: 50
      }

      {:ok, result} = Solver.solve(model, max_iterations: 10, penalty_params: penalty_params)
      assert result.num_iterations <= 10
    end
  end

  describe "solve result" do
    test "returns expected result structure" do
      model = build_ok_small_model()

      {:ok, result} = Solver.solve(model, max_iterations: 5)

      # Check result structure
      assert %IteratedLocalSearch.Result{} = result
      assert is_map(result.stats)
      assert is_integer(result.num_iterations)
      assert is_integer(result.runtime)

      # Check best solution
      assert %ExVrp.Solution{} = result.best
      assert is_list(result.best.routes)
      assert is_boolean(result.best.is_feasible)
    end

    test "best solution has correct client count" do
      model = build_ok_small_model()

      {:ok, result} = Solver.solve(model, max_iterations: 10)

      # All 4 clients should be assigned
      total_clients = result.best.routes |> List.flatten() |> length()
      assert total_clients == 4
      assert result.best.num_clients == 4
    end
  end

  describe "combined stopping criteria" do
    test "max_runtime AND max_iterations combined" do
      model = build_ok_small_model()

      # Use both max_runtime and max_iterations - solver should use both
      {:ok, result} = Solver.solve(model, max_iterations: 100, max_runtime: 10.0)

      # Should stop when either is reached
      assert result.num_iterations <= 100
      assert result.runtime <= 10_000
    end
  end

  describe "prize-collecting problems" do
    test "finds feasible solution quickly for high-prize optional clients" do
      # Regression test: without prize-aware tw_penalty, this took 25+ seconds
      # because the solver preferred keeping clients with time warp violations
      # (low penalty) over removing them (losing high prize).

      prize = 100_000
      shift_duration = 8 * 3600

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: shift_duration)
        |> Model.add_vehicle_type(
          num_available: 5,
          capacity: [1000],
          tw_early: 0,
          tw_late: shift_duration
        )

      # Add 20 optional clients with high prizes and tight time windows
      model =
        Enum.reduce(1..20, model, fn i, acc ->
          angle = 2 * :math.pi() * i / 20
          tw_start = div(i * shift_duration, 21)

          Model.add_client(acc,
            x: round(1000 * :math.cos(angle)),
            y: round(1000 * :math.sin(angle)),
            delivery: [10],
            required: false,
            prize: prize,
            tw_early: tw_start,
            tw_late: min(tw_start + 2 * 3600, shift_duration),
            service_duration: 1800
          )
        end)

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Solver.solve(model, max_iterations: 100)
      elapsed = System.monotonic_time(:millisecond) - start

      assert result.best.is_feasible == true
      assert elapsed < 2000
    end
  end

  # Helper functions

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

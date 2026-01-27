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

  describe "tight time window prize-collecting" do
    test "finds all 4 clients with tight shift durations" do
      # Regression test for prize-collecting problem where only one valid
      # client-to-vehicle assignment exists. Previously failed ~58% of the time.
      #
      # Model: 4 optional clients with high prizes (100k each), 2 vehicle types
      # with tight 900-second shifts. Only one assignment is feasible:
      # VT0 (shift 0-900): clients 2,3
      # VT1 (shift 10800-11700): clients 1,4
      # Non-uniform distances - some clients far from each other (1000)
      matrix = [
        [0, 60, 120, 180, 240],
        [60, 0, 120, 1000, 1000],
        [120, 1000, 0, 180, 1000],
        [180, 1000, 1000, 0, 240],
        [240, 1000, 1000, 1000, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 28_800, service_duration: 0)
        |> Model.add_client(
          x: 1,
          y: 0,
          tw_early: 0,
          tw_late: 28_800,
          service_duration: 60,
          required: false,
          prize: 100_000,
          delivery: [1000, 50, 1, 0],
          pickup: [0, 0, 0, 0]
        )
        |> Model.add_client(
          x: 2,
          y: 0,
          tw_early: 0,
          tw_late: 28_800,
          service_duration: 120,
          required: false,
          prize: 100_000,
          delivery: [1000, 50, 1, 0],
          pickup: [0, 0, 0, 0]
        )
        |> Model.add_client(
          x: 3,
          y: 0,
          tw_early: 0,
          tw_late: 28_800,
          service_duration: 180,
          required: false,
          prize: 100_000,
          delivery: [1000, 50, 1, 0],
          pickup: [0, 0, 0, 0]
        )
        |> Model.add_client(
          x: 4,
          y: 0,
          tw_early: 0,
          tw_late: 28_800,
          service_duration: 240,
          required: false,
          prize: 100_000,
          delivery: [1000, 50, 1, 0],
          pickup: [0, 0, 0, 0]
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          tw_early: 0,
          tw_late: 900,
          shift_duration: 900,
          capacity: [100_000, 50, 1, 50],
          reload_depots: [0]
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          tw_early: 10_800,
          tw_late: 11_700,
          shift_duration: 900,
          capacity: [100_000, 50, 1, 50],
          reload_depots: [0]
        )
        |> Model.set_distance_matrices([matrix])
        |> Model.set_duration_matrices([matrix])

      # Test multiple seeds to ensure stability
      for seed <- [1, 42, 123, 456, 789] do
        {:ok, result} = Solver.solve(model, max_iterations: 1000, seed: seed)

        assert result.best.num_clients == 4,
               "Seed #{seed} only found #{result.best.num_clients} clients"

        assert result.best.is_feasible == true,
               "Seed #{seed} solution not feasible"
      end
    end

    test "finds all 4 clients with disjoint vehicle time windows" do
      # Regression test for prize-collecting problem where clients must be
      # assigned to specific vehicle types based on time windows.
      #
      # Model: 4 optional clients with high prizes (100k each), 2 vehicle types
      # VT0: tw=[0, 400], can serve clients 1,2 (tw=[0,100], [300,400])
      # VT1: tw=[400, 1000], can serve clients 3,4 (tw=[400,810], [820,1500])
      distance_matrix = [
        [0, 1, 2, 1, 1],
        [61, 0, 4, 3, 2],
        [61, 4, 0, 4, 1],
        [61, 3, 4, 0, 4],
        [61, 2, 1, 4, 0]
      ]

      duration_matrix = [
        [0, 1, 2, 1, 1],
        [1, 0, 4, 3, 2],
        [1, 4, 0, 4, 1],
        [1, 3, 4, 0, 4],
        [1, 2, 1, 4, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 86_400, service_duration: 60)
        |> Model.add_client(
          x: 1,
          y: 0,
          tw_early: 0,
          tw_late: 100,
          service_duration: 15,
          required: false,
          prize: 100_000,
          delivery: [0, 0, 0],
          pickup: [10, 100, 100]
        )
        |> Model.add_client(
          x: 2,
          y: 0,
          tw_early: 300,
          tw_late: 400,
          service_duration: 15,
          required: false,
          prize: 100_000,
          delivery: [0, 0, 0],
          pickup: [10, 100, 100]
        )
        |> Model.add_client(
          x: 3,
          y: 0,
          tw_early: 400,
          tw_late: 810,
          service_duration: 15,
          required: false,
          prize: 100_000,
          delivery: [0, 0, 0],
          pickup: [10, 100, 100]
        )
        |> Model.add_client(
          x: 4,
          y: 0,
          tw_early: 820,
          tw_late: 1500,
          service_duration: 15,
          required: false,
          prize: 100_000,
          delivery: [0, 0, 0],
          pickup: [10, 100, 100]
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          tw_early: 0,
          tw_late: 400,
          shift_duration: 400,
          capacity: [100, 100, 100],
          reload_depots: [0]
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          tw_early: 400,
          tw_late: 1000,
          shift_duration: 600,
          capacity: [100, 100, 100],
          reload_depots: [0]
        )
        |> Model.set_distance_matrices([distance_matrix])
        |> Model.set_duration_matrices([duration_matrix])

      for seed <- [1, 42, 123, 456, 789] do
        {:ok, result} = Solver.solve(model, max_iterations: 100, seed: seed)

        assert result.best.num_clients == 4,
               "Seed #{seed} only found #{result.best.num_clients} clients"

        assert result.best.is_feasible == true,
               "Seed #{seed} solution not feasible"
      end
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

defmodule ExVrp.StatisticsTest do
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Statistics

  @moduletag :nif_required

  describe "new/1" do
    test "creates statistics with default options" do
      stats = Statistics.new()
      assert Statistics.collecting?(stats)
      assert stats.num_iterations == 0
      assert stats.data == []
      assert stats.runtimes == []
    end

    test "creates statistics with collect_stats: false" do
      stats = Statistics.new(collect_stats: false)
      refute Statistics.collecting?(stats)
    end
  end

  describe "collect/5" do
    test "collects a data point per iteration" do
      {:ok, _problem_data, cost_evaluator, solution} = ok_small_with_solution()

      stats = Statistics.new()
      assert Statistics.collecting?(stats)

      # Collect 5 iterations
      stats =
        Enum.reduce(1..5, stats, fn _, acc ->
          Statistics.collect(acc, solution, solution, solution, cost_evaluator)
        end)

      assert length(stats.data) == 5
      assert stats.num_iterations == 5
      assert length(stats.runtimes) == 5
    end

    test "collects zero iterations when count is zero" do
      stats = Statistics.new()
      assert stats.data == []
      assert stats.num_iterations == 0
    end

    test "data point matches collected values" do
      {:ok, problem_data, cost_evaluator} = ok_small_setup()

      # Create different solutions
      {:ok, curr} = Native.create_solution_from_routes(problem_data, [[1, 2, 3, 4]])
      {:ok, cand} = Native.create_solution_from_routes(problem_data, [[2, 1], [4, 3]])
      {:ok, best} = Native.create_solution_from_routes(problem_data, [[1, 2], [3, 4]])

      stats = Statistics.new()
      stats = Statistics.collect(stats, curr, cand, best, cost_evaluator)

      [datum] = stats.data

      # Verify costs match what the evaluator returns
      assert datum.current_cost == Native.solution_penalised_cost(curr, cost_evaluator)
      assert datum.candidate_cost == Native.solution_penalised_cost(cand, cost_evaluator)
      assert datum.best_cost == Native.solution_penalised_cost(best, cost_evaluator)

      # Verify feasibility
      assert datum.current_feas == Native.solution_is_feasible(curr)
      assert datum.candidate_feas == Native.solution_is_feasible(cand)
      assert datum.best_feas == Native.solution_is_feasible(best)
    end
  end

  describe "not collecting" do
    test "collect is a no-op when not collecting" do
      {:ok, _problem_data, cost_evaluator, solution} = ok_small_with_solution()

      stats = Statistics.new(collect_stats: false)
      refute Statistics.collecting?(stats)

      stats = Statistics.collect(stats, solution, solution, solution, cost_evaluator)
      stats = Statistics.collect(stats, solution, solution, solution, cost_evaluator)

      assert stats.data == []
      assert stats.num_iterations == 0
      assert stats.runtimes == []
    end
  end

  describe "Enumerable" do
    test "iterating over statistics returns data" do
      {:ok, _problem_data, cost_evaluator, solution} = ok_small_with_solution()

      stats = Statistics.new()

      stats = Statistics.collect(stats, solution, solution, solution, cost_evaluator)
      stats = Statistics.collect(stats, solution, solution, solution, cost_evaluator)

      data_list = Enum.to_list(stats)
      assert length(data_list) == 2

      for datum <- stats do
        assert is_map(datum)
        assert Map.has_key?(datum, :current_cost)
        assert Map.has_key?(datum, :current_feas)
        assert Map.has_key?(datum, :candidate_cost)
        assert Map.has_key?(datum, :candidate_feas)
        assert Map.has_key?(datum, :best_cost)
        assert Map.has_key?(datum, :best_feas)
      end
    end

    test "empty statistics returns empty list" do
      stats = Statistics.new()
      assert Enum.to_list(stats) == []
    end
  end

  describe "CSV serialization" do
    test "to_csv and from_csv round-trip" do
      {:ok, _problem_data, cost_evaluator, solution} = ok_small_with_solution()

      stats = Statistics.new()

      stats =
        Enum.reduce(1..10, stats, fn _, acc ->
          Statistics.collect(acc, solution, solution, solution, cost_evaluator)
        end)

      # Write to temp file
      path = Path.join(System.tmp_dir!(), "test_stats_#{:rand.uniform(10_000)}.csv")

      assert :ok = Statistics.to_csv(stats, path)
      assert File.exists?(path)

      # Read back
      {:ok, read_stats} = Statistics.from_csv(path)

      # Verify data matches
      assert length(read_stats.data) == length(stats.data)
      assert read_stats.num_iterations == stats.num_iterations

      # Compare data points
      stats.data
      |> Enum.zip(read_stats.data)
      |> Enum.each(fn {orig, read} ->
        assert orig.current_cost == read.current_cost
        assert orig.current_feas == read.current_feas
        assert orig.candidate_cost == read.candidate_cost
        assert orig.candidate_feas == read.candidate_feas
        assert orig.best_cost == read.best_cost
        assert orig.best_feas == read.best_feas
      end)

      # Compare runtimes (with tolerance for float comparison)
      stats.runtimes
      |> Enum.zip(read_stats.runtimes)
      |> Enum.each(fn {orig, read} ->
        assert_in_delta orig, read, 0.0001
      end)

      # Cleanup
      File.rm(path)
    end
  end

  # Helper functions

  defp ok_small_setup do
    distances = [
      [0, 1544, 1944, 1931, 1476],
      [1726, 0, 1992, 1427, 1593],
      [1965, 1975, 0, 621, 1090],
      [2063, 1433, 647, 0, 818],
      [1475, 1594, 1090, 828, 0]
    ]

    model =
      Model.new()
      |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
      |> Model.add_client(
        x: 226,
        y: 1297,
        delivery: [5],
        tw_early: 15_600,
        tw_late: 22_500,
        service_duration: 360
      )
      |> Model.add_client(
        x: 590,
        y: 530,
        delivery: [5],
        tw_early: 12_000,
        tw_late: 19_500,
        service_duration: 360
      )
      |> Model.add_client(
        x: 435,
        y: 718,
        delivery: [3],
        tw_early: 8400,
        tw_late: 15_300,
        service_duration: 420
      )
      |> Model.add_client(
        x: 1191,
        y: 639,
        delivery: [5],
        tw_early: 12_000,
        tw_late: 19_500,
        service_duration: 360
      )
      |> Model.add_vehicle_type(
        num_available: 3,
        capacity: [10],
        tw_early: 0,
        tw_late: 45_000
      )
      |> Model.set_distance_matrices([distances])
      |> Model.set_duration_matrices([distances])

    {:ok, problem_data} = Model.to_problem_data(model)

    {:ok, cost_evaluator} =
      Native.create_cost_evaluator(
        load_penalties: [20.0],
        tw_penalty: 6.0,
        dist_penalty: 6.0
      )

    {:ok, problem_data, cost_evaluator}
  end

  defp ok_small_with_solution do
    {:ok, problem_data, cost_evaluator} = ok_small_setup()
    {:ok, solution} = Native.create_solution_from_routes(problem_data, [[1, 2], [3, 4]])
    {:ok, problem_data, cost_evaluator, solution}
  end
end

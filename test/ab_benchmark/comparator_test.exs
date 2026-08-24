defmodule ExVrp.ABBenchmark.ComparatorTest do
  use ExUnit.Case, async: true

  alias ExVrp.ABBenchmark.Comparator

  @warn_threshold 0.01

  defp results(ref, instances), do: %{"ref" => ref, "commit" => "abc", "instances" => instances}

  defp inst(variant, bks, seeds), do: %{"variant" => variant, "bks" => bks, "seeds" => seeds}

  defp seed(obj, feasible), do: %{"objective" => obj, "feasible" => feasible, "time_ms" => 1, "iterations" => 1}

  test "mean_objective averages feasible seeds only" do
    base =
      results("main", %{
        "a" => inst("cvrp", 100, %{"1" => seed(110, true), "2" => seed(130, true), "3" => seed(999, false)})
      })

    cand = base
    %{per_instance: [row]} = Comparator.analyze(base, cand)
    assert row.baseline_mean == 120.0
  end

  test "gap_to_bks is computed per ref when bks present" do
    base = results("main", %{"a" => inst("cvrp", 100, %{"1" => seed(110, true)})})
    cand = results("head", %{"a" => inst("cvrp", 100, %{"1" => seed(120, true)})})
    %{per_instance: [row]} = Comparator.analyze(base, cand)
    assert_in_delta row.baseline_gap, 0.10, 1.0e-9
    assert_in_delta row.candidate_gap, 0.20, 1.0e-9
  end

  test "clean when candidate equals baseline" do
    base = results("main", %{"a" => inst("cvrp", 100, %{"1" => seed(110, true)})})
    assert {:ok, summary} = Comparator.compare(base, base)
    assert summary.hard_fails == []
    assert summary.warnings == []
  end

  test "hard fail when an instance goes feasible -> infeasible" do
    base = results("main", %{"a" => inst("cvrp", 100, %{"1" => seed(110, true)})})
    cand = results("head", %{"a" => inst("cvrp", 100, %{"1" => seed(110, false)})})
    assert {:regression, summary} = Comparator.compare(base, cand)
    assert Enum.any?(summary.hard_fails, &String.contains?(&1, "infeasible"))
  end

  test "hard fail when aggregate objective worsens beyond 0.5%" do
    base = results("main", %{"a" => inst("cvrp", 100, %{"1" => seed(100, true)})})
    cand = results("head", %{"a" => inst("cvrp", 100, %{"1" => seed(101, true)})})
    assert {:regression, summary} = Comparator.compare(base, cand)
    assert Enum.any?(summary.hard_fails, &String.contains?(&1, "objective"))
  end

  test "hard fail when a production instance objective worsens beyond 0.5%" do
    base = results("main", %{"p" => inst("production", nil, %{"1" => seed(1000, true)})})
    cand = results("head", %{"p" => inst("production", nil, %{"1" => seed(1010, true)})})
    assert {:regression, summary} = Comparator.compare(base, cand)
    assert Enum.any?(summary.hard_fails, &String.contains?(&1, "objective"))
  end

  test "hard fail when an instance present in baseline is missing from candidate" do
    base =
      results("main", %{
        "a" => inst("cvrp", 100, %{"1" => seed(100, true)}),
        "gone" => inst("cvrp", 100, %{"1" => seed(100, true)})
      })

    cand = results("head", %{"a" => inst("cvrp", 100, %{"1" => seed(100, true)})})
    assert {:regression, summary} = Comparator.compare(base, cand)
    assert Enum.any?(summary.hard_fails, &String.contains?(&1, "gone"))
  end

  test "noise is the spread of paired per-seed deltas, not the scatter of raw objectives" do
    base = results("main", %{"a" => inst("cvrp", nil, %{"1" => seed(900, true), "2" => seed(1100, true)})})
    cand = results("head", %{"a" => inst("cvrp", nil, %{"1" => seed(909, true), "2" => seed(1111, true)})})

    %{per_instance: [row]} = Comparator.analyze(base, cand)
    assert_in_delta row.noise, 0.0, 1.0e-9
    assert_in_delta row.pct_change, 0.01, 1.0e-9
  end

  test "a shift every seed agrees on is a result even when the seeds scatter" do
    scattered = fn objs ->
      seeds = objs |> Enum.with_index(1) |> Map.new(fn {o, i} -> {to_string(i), seed(o, true)} end)
      inst("production", nil, seeds)
    end

    base = results("main", %{"noisy" => scattered.([900, 1100])})
    cand = results("head", %{"noisy" => scattered.([918, 1122])})

    %{per_instance: [row]} = Comparator.analyze(base, cand)
    assert row.pct_change > row.noise

    assert {:regression, summary} = Comparator.compare(base, cand)
    assert Enum.any?(summary.warnings, &String.contains?(&1, "noisy"))
  end

  test "a regression smaller than the instance's own noise does not warn" do
    scattered = fn objs ->
      seeds = objs |> Enum.with_index(1) |> Map.new(fn {o, i} -> {to_string(i), seed(o, true)} end)
      inst("production", nil, seeds)
    end

    steady = inst("cvrp", nil, %{"1" => seed(1000, true)})
    quiet = %{"a" => steady, "b" => steady, "c" => steady, "d" => steady}

    base = results("main", Map.put(quiet, "noisy", scattered.([1000, 1000])))
    cand = results("head", Map.put(quiet, "noisy", scattered.([1200, 830])))

    %{per_instance: rows} = Comparator.analyze(base, cand)
    row = Enum.find(rows, &(&1.id == "noisy"))
    assert row.pct_change > @warn_threshold
    assert row.pct_change < row.noise

    assert {:ok, summary} = Comparator.compare(base, cand)
    assert summary.warnings == []
  end

  test "seeds are paired by seed id, not by position" do
    base = results("main", %{"a" => inst("cvrp", nil, %{"1" => seed(1000, true), "2" => seed(2000, true)})})
    cand = results("head", %{"a" => inst("cvrp", nil, %{"2" => seed(2020, true), "1" => seed(1010, true)})})

    %{per_instance: [row]} = Comparator.analyze(base, cand)
    assert_in_delta row.noise, 0.0, 1.0e-9
  end

  test "a seed feasible in only one ref is excluded from the band" do
    base = results("main", %{"a" => inst("cvrp", nil, %{"1" => seed(1000, true), "2" => seed(2000, true)})})
    cand = results("head", %{"a" => inst("cvrp", nil, %{"1" => seed(1010, true), "2" => seed(9999, false)})})

    %{per_instance: [row]} = Comparator.analyze(base, cand)
    assert_in_delta row.noise, 0.0, 1.0e-9
  end

  test "iteration throughput is reported alongside the objective" do
    with_iters = fn obj, iters ->
      inst("cvrp", nil, %{"1" => %{"objective" => obj, "feasible" => true, "time_ms" => 1, "iterations" => iters}})
    end

    base = results("main", %{"a" => with_iters.(1000, 1000)})
    cand = results("head", %{"a" => with_iters.(1000, 500)})

    %{per_instance: [row]} = Comparator.analyze(base, cand)
    assert_in_delta row.iter_pct_change, -0.5, 1.0e-9
  end

  test "warn only for a localized >1% objective regression that doesn't move aggregate gap past 0.5pp" do
    clean = inst("cvrp", 1000, %{"1" => seed(1000, true)})
    base = results("main", %{"a" => clean, "b" => clean, "c" => clean, "d" => clean})

    cand =
      results("head", %{
        "a" => clean,
        "b" => clean,
        "c" => clean,
        "d" => inst("cvrp", 1000, %{"1" => seed(1015, true)})
      })

    assert {:ok, summary} = Comparator.compare(base, cand)
    assert summary.hard_fails == []
    assert Enum.any?(summary.warnings, &String.contains?(&1, "d"))
  end
end

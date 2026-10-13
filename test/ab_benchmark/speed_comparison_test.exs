defmodule ExVrp.ABBenchmark.SpeedComparisonTest do
  use ExUnit.Case, async: true

  alias ExVrp.ABBenchmark.SpeedComparison

  defp speed(instances) do
    records =
      Map.new(instances, fn {id, {count, distances}} ->
        {id, %{"instructions_per_iteration" => count, "distances" => distances, "iterations" => [10, 30]}}
      end)

    %{"ref" => "r", "commit" => "c", "instances" => records}
  end

  defp same_path(counts), do: Map.new(counts, fn {id, count} -> {id, {count, [100, 90]}} end)

  test "pct_change is the candidate's instruction count relative to the baseline's" do
    base = speed(same_path(%{"a" => 2.0e6}))
    cand = speed(same_path(%{"a" => 2.1e6}))

    assert %{rows: [row], missing: []} = SpeedComparison.analyze(base, cand)
    assert_in_delta row.pct_change, 0.05, 1.0e-9
    refute row.path_changed
  end

  test "different final distances mark the search path as changed" do
    base = speed(%{"a" => {1.0e6, [100, 90]}})
    cand = speed(%{"a" => {1.0e6, [100, 89]}})

    assert %{rows: [%{path_changed: true}]} = SpeedComparison.analyze(base, cand)
  end

  test "the median instance slowing by more than 1% fails" do
    base = speed(same_path(%{"a" => 1.0e6, "b" => 1.0e6, "c" => 1.0e6}))
    cand = speed(same_path(%{"a" => 1.015e6, "b" => 1.012e6, "c" => 0.99e6}))

    assert [fail] = base |> SpeedComparison.analyze(cand) |> SpeedComparison.hard_fails()
    assert fail =~ "slower"
  end

  test "one instance slowing by more than 2% warns but does not fail" do
    base = speed(same_path(%{"a" => 1.0e6, "b" => 1.0e6, "c" => 1.0e6}))
    cand = speed(same_path(%{"a" => 1.05e6, "b" => 1.0e6, "c" => 1.0e6}))
    comparison = SpeedComparison.analyze(base, cand)

    assert SpeedComparison.hard_fails(comparison) == []
    assert [warning] = SpeedComparison.warnings(comparison.rows)
    assert warning =~ "a:"
  end

  test "an instance measured on baseline but not on candidate fails" do
    base = speed(same_path(%{"a" => 1.0e6, "gone" => 1.0e6}))
    cand = speed(same_path(%{"a" => 1.0e6}))

    assert [fail] = base |> SpeedComparison.analyze(cand) |> SpeedComparison.hard_fails()
    assert fail =~ "gone"
  end

  test "changes within the measurement's repeatability are not results" do
    base = speed(same_path(%{"steady" => 1.0e6, "faster" => 1.0e6}))
    cand = speed(same_path(%{"steady" => 1.002e6, "faster" => 0.97e6}))

    assert [result] = SpeedComparison.results(SpeedComparison.analyze(base, cand).rows)
    assert result =~ "faster"
  end
end

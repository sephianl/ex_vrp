defmodule ExVrp.ABBenchmark.ReportTest do
  use ExUnit.Case, async: true

  alias ExVrp.ABBenchmark.Comparator
  alias ExVrp.ABBenchmark.Report

  defp results(objective) do
    seeds = %{"1" => %{"objective" => objective, "feasible" => true, "time_ms" => 1, "iterations" => 1}}
    %{"ref" => "r", "commit" => "c", "instances" => %{"a" => %{"variant" => "cvrp", "bks" => nil, "seeds" => seeds}}}
  end

  defp speed(count) do
    record = %{"instructions_per_iteration" => count, "distances" => [100, 90], "iterations" => [10, 30]}
    %{"ref" => "r", "commit" => "c", "instances" => %{"a" => record}}
  end

  test "an unchanged candidate opens with PASS and says nothing moved" do
    {:ok, summary} = Comparator.compare(results(1000), results(1000), speed(1.0e6), speed(1.0e6))
    report = Report.render(summary, :text)

    assert String.starts_with?(report, "PASS\n")
    assert report =~ "Nothing moved beyond its noise."
    assert report =~ "instructions per search iteration"
  end

  test "a regression opens with FAIL and its reason" do
    {:regression, summary} = Comparator.compare(results(1000), results(1100), nil, nil)
    report = Report.render(summary, :text)

    assert String.starts_with?(report, "FAIL\nFAIL: aggregate objective worsened")
  end

  test "an unmeasured speed is said in the verdict" do
    {:ok, summary} = Comparator.compare(results(1000), results(1000), nil, nil)
    assert Report.render(summary, :text) =~ "Speed not measured"
  end

  test "markdown folds the tables away under the verdict" do
    {:ok, summary} = Comparator.compare(results(1000), results(1000), speed(1.0e6), speed(1.0e6))
    markdown = Report.render(summary, :markdown)

    [verdict, tables] = String.split(markdown, "<details>")
    assert verdict =~ "PASS"
    refute verdict =~ "Gap b->c"
    assert tables =~ "Gap b->c"
  end
end

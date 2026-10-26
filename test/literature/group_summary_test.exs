defmodule ExVrp.Literature.GroupSummaryTest do
  use ExUnit.Case, async: true

  alias ExVrp.Literature.GroupSummary

  defp record(instance, seed, objective, trace) do
    %{
      "group" => "cvrp",
      "instance" => instance,
      "num_clients" => 100,
      "seed" => seed,
      "bks" => 1000,
      "best_known" => 1000,
      "optimal" => true,
      "feasible" => objective != nil,
      "objective" => objective,
      "budget_s" => 10.0,
      "time_ms" => 10_000,
      "iterations" => 5000,
      "trace" => trace
    }
  end

  test "averages seeds per instance before weighing instances equally" do
    [summary] =
      GroupSummary.from_records([
        record("a", 1, 1010, [[1000, 1050], [9000, 1010]]),
        record("a", 2, 1030, [[1000, 1030]]),
        record("b", 1, 1000, [[6000, 1000]])
      ])

    assert summary.instances == 2
    assert summary.seeds == 2
    assert_in_delta summary.mean_gap_to_bks, (0.02 + 0.0) / 2, 1.0e-9
    assert_in_delta summary.best_of_seeds_gap, (0.01 + 0.0) / 2, 1.0e-9
    assert summary.optimum_reached == 1
    assert summary.proven_optimal == 2
  end

  test "the gap at a fraction of the budget is the last trace point by then" do
    [summary] = GroupSummary.from_records([record("a", 1, 1010, [[1000, 1050], [9000, 1010]])])

    assert [{0.1, gap_at_10}, {0.25, _gap}, {0.5, _gap_at_50}, {1.0, gap_at_100}] = summary.gap_over_budget
    assert_in_delta gap_at_10, 0.05, 1.0e-9
    assert_in_delta gap_at_100, 0.01, 1.0e-9
  end

  test "an instance with no feasible seed is reported, not averaged" do
    [summary] = GroupSummary.from_records([record("a", 1, 1010, [[1000, 1010]]), record("b", 1, nil, [])])

    assert summary.unsolved_instances == ["b"]
    assert summary.infeasible_solves == 1
    assert_in_delta summary.mean_gap_to_bks, 0.01, 1.0e-9
  end

  test "compares with PyVRP's published gap within two standard errors as noise" do
    close = for {name, objective} <- [{"a", 1002}, {"b", 1004}, {"c", 1003}], do: record(name, 1, objective, [])
    far = for {name, objective} <- [{"a", 1020}, {"b", 1021}, {"c", 1019}], do: record(name, 1, objective, [])

    assert {:within_noise, _difference} =
             close |> GroupSummary.from_records() |> hd() |> GroupSummary.pyvrp_comparison("0.13.0")

    assert {:worse, difference} = far |> GroupSummary.from_records() |> hd() |> GroupSummary.pyvrp_comparison("0.13.0")
    assert_in_delta difference, 0.02 - 0.0031, 1.0e-9
  end
end

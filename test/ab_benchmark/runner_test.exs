defmodule ExVrp.ABBenchmark.RunnerTest do
  use ExUnit.Case, async: false

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Runner

  test "run/1 produces the documented results shape" do
    entry = Enum.find(Corpus.entries(), &(&1.id == "ok_small"))
    results = Runner.run(entries: [entry], seeds: [1, 2], budget_s: 1.0, ref: "test-ref", commit: "deadbeef")

    assert results["ref"] == "test-ref"
    assert results["commit"] == "deadbeef"
    inst = results["instances"]["ok_small"]
    assert inst["variant"] == "vrptw"
    assert map_size(inst["seeds"]) == 2
    seed1 = inst["seeds"]["1"]
    assert is_number(seed1["objective"])
    assert is_boolean(seed1["feasible"])
    assert is_integer(inst["feasible_count"])
  end

  test "an instance that fails to load is recorded as infeasible, not omitted" do
    bad = %Corpus.Entry{id: "broken", variant: :cvrp, kind: :vrplib, path: "/nonexistent/nope.vrp", round_func: :round}
    results = Runner.run(entries: [bad], seeds: [1, 2], budget_s: 1.0, ref: "r", commit: "c")

    inst = results["instances"]["broken"]
    assert inst
    assert inst["feasible_count"] == 0
    assert Enum.all?(inst["seeds"], fn {_s, m} -> m["feasible"] == false end)
  end
end

defmodule ExVrp.ABBenchmark.SpeedTest do
  use ExUnit.Case, async: true

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Speed

  test "every speed corpus instance is in the benchmark corpus" do
    corpus_ids = MapSet.new(Corpus.entries(), & &1.id)
    assert Enum.all?(Speed.corpus(), fn {id, _iterations} -> MapSet.member?(corpus_ids, id) end)
  end

  test "reads the instruction count from perf stat's CSV output" do
    csv = "# started on Mon Oct 12 2026\n\n4421052812,,instructions:u,5153661374,100.00,,\n"
    assert Speed.instructions_from_perf_csv(csv) == {:ok, 4_421_052_812}
  end

  test "a machine without an instruction counter is an error, not a zero count" do
    csv = "<not supported>,,instructions:u,0,100.00,,\n"
    assert {:error, reason} = Speed.instructions_from_perf_csv(csv)
    assert reason =~ "no instruction counter"
  end

  test "reads the final distance from the solve's output, past the solver's logging" do
    output = "make: Nothing to be done for 'all'.\nBENCH_SPEED distance=4711\n"
    assert Speed.distance_from_solve_output(output) == {:ok, 4711}
  end

  test "a solve that printed no distance is an error" do
    assert {:error, _reason} = Speed.distance_from_solve_output("** (MatchError) no match\n")
  end
end

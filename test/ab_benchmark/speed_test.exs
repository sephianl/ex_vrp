defmodule ExVrp.ABBenchmark.SpeedTest do
  use ExUnit.Case, async: true

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Speed

  test "every speed corpus instance is in the benchmark corpus" do
    corpus_ids = MapSet.new(Corpus.entries(), & &1.id)
    assert Enum.all?(Speed.corpus(), fn {id, _iterations} -> MapSet.member?(corpus_ids, id) end)
  end

  test "reads the instruction count from Callgrind's totals line" do
    callgrind_out = "version: 1\ncreator: callgrind-3.27.1\nevents: Ir\nsummary: 908441628\ntotals: 908441628\n"
    assert Speed.instructions_from_callgrind_out(callgrind_out) == 908_441_628
  end

  test "a process Callgrind traced but never counted in contributes nothing" do
    assert Speed.instructions_from_callgrind_out("version: 1\nevents: Ir\n") == 0
  end

  test "reads the final distance from the solve's output, past the solver's logging" do
    output = "make: Nothing to be done for 'all'.\nBENCH_SPEED distance=4711\n"
    assert Speed.distance_from_solve_output(output) == {:ok, 4711}
  end

  test "a solve that printed no distance is an error" do
    assert {:error, _reason} = Speed.distance_from_solve_output("** (MatchError) no match\n")
  end
end

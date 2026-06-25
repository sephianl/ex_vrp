defmodule ExVrp.ABBenchmark.LoaderTest do
  use ExUnit.Case, async: true

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Loader

  test "loads a VRPLIB literature entry into a model" do
    entry = Enum.find(Corpus.entries(), &(&1.id == "ok_small"))
    model = Loader.load(entry)
    assert ExVrp.Model.num_locations(model) > 0
  end

  test "loads an ETF production entry into a model (if any exist)" do
    case Enum.find(Corpus.entries(), &(&1.kind == :etf)) do
      nil ->
        assert true

      entry ->
        model = Loader.load(entry)
        assert ExVrp.Model.num_locations(model) > 0
    end
  end
end

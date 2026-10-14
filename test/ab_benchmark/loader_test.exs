defmodule ExVrp.ABBenchmark.LoaderTest do
  use ExUnit.Case, async: true

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Instance
  alias ExVrp.ABBenchmark.Loader
  alias ExVrp.PenaltyManager

  test "loads a VRPLIB literature entry into a model under the default penalty bounds" do
    entry = Enum.find(Corpus.entries(), &(&1.id == "ok_small"))
    %Instance{model: model, penalty_params: penalty_params} = Loader.load(entry)
    assert ExVrp.Model.num_locations(model) > 0
    assert penalty_params == %PenaltyManager.Params{}
  end

  test "loads an ETF production entry into a model (if any exist)" do
    case Enum.find(Corpus.entries(), &(&1.kind == :etf)) do
      nil ->
        assert true

      entry ->
        %Instance{model: model} = Loader.load(entry)
        assert ExVrp.Model.num_locations(model) > 0
    end
  end

  test "a capture priced in micro-euros carries the penalty bounds Zelo solves it under" do
    entry = Enum.find(Corpus.entries(), &(&1.id == "prod_clients_017"))
    %Instance{penalty_params: penalty_params} = Loader.load(entry)
    assert penalty_params.max_penalty > %PenaltyManager.Params{}.max_penalty
  end
end

defmodule Mix.Tasks.Bench.Speed do
  @shortdoc "Count the solver's instructions per iteration on the speed corpus and write JSON"

  @moduledoc """
  Measures `ExVrp.ABBenchmark.Speed`'s corpus on the current checkout and writes a speed JSON.

      mix bench.speed --out speed-head.json --ref head
      mix bench.speed --out s.json --only pc_R1_10_4,c201

  Needs `perf` on the PATH and a machine that exposes hardware counters. Build the NIF
  first: each solve runs `mix run --no-compile`, so it measures what is already built.

  Options:
    --out   Output JSON path (required)
    --ref   Label for this run (default: current git branch)
    --only  Comma-separated instance ids to restrict the corpus
  """
  use Mix.Task

  alias ExVrp.ABBenchmark.Checkout
  alias ExVrp.ABBenchmark.Speed

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {parsed, _, _} = OptionParser.parse(args, switches: [out: :string, ref: :string, only: :string])
    out = parsed[:out] || raise "--out is required"
    ref = parsed[:ref] || Checkout.branch()
    commit = Checkout.commit()
    corpus = restrict_corpus(Speed.corpus(), parsed[:only])

    results = Speed.run(corpus, ref, commit)
    File.write!(out, Jason.encode!(results, pretty: true))
    Mix.shell().info("Wrote #{out} (ref=#{ref}, commit=#{commit}, instances=#{map_size(results["instances"])})")
  end

  defp restrict_corpus(corpus, nil), do: corpus

  defp restrict_corpus(corpus, only) do
    ids = MapSet.new(String.split(only, ","))
    Enum.filter(corpus, fn {id, _iterations} -> MapSet.member?(ids, id) end)
  end
end

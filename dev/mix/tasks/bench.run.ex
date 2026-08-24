defmodule Mix.Tasks.Bench.Run do
  @shortdoc "Solve the A/B benchmark corpus on the current checkout and write results JSON"

  @moduledoc """
  Runs the A/B benchmark corpus and writes a results JSON.

      mix bench.run --out results-head.json --ref general-updates
      mix bench.run --out r.json --seeds 1,2,3 --budget-cap 120
      mix bench.run --out r.json --only ok_small,rc208 --budget 2

  Options:
    --out         Output JSON path (required)
    --ref         Label for this run (default: current git branch)
    --seeds       Comma-separated seeds (default: 1,2,3)
    --budget-cap  Per-instance budget cap in seconds (default: 180)
    --budget      Fixed per-instance budget in seconds (overrides size-scaling; useful for smoke runs)
    --only        Comma-separated instance ids to restrict the corpus
  """
  use Mix.Task

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Runner

  require Logger

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          out: :string,
          ref: :string,
          seeds: :string,
          budget_cap: :integer,
          budget: :float,
          only: :string
        ]
      )

    Application.ensure_all_started(:ex_vrp)
    out = opts[:out] || raise "--out is required"
    ref = opts[:ref] || git("rev-parse", ["--abbrev-ref", "HEAD"])
    commit = git("rev-parse", ["--short", "HEAD"])
    seeds = parse_seeds(opts[:seeds])
    entries = filter_entries(Corpus.entries(), opts[:only])

    run_opts =
      [entries: entries, seeds: seeds, ref: ref, commit: commit]
      |> maybe_put(:budget_cap_s, opts[:budget_cap] && :erlang.float(opts[:budget_cap]))
      |> maybe_put(:budget_s, opts[:budget])

    results = quiet(fn -> Runner.run(run_opts) end)
    File.write!(out, Jason.encode!(results, pretty: true))
    Mix.shell().info("Wrote #{out} (ref=#{ref}, commit=#{commit}, instances=#{map_size(results["instances"])})")
  end

  defp quiet(fun) do
    prev = Logger.level()
    Logger.configure(level: :warning)
    result = fun.()
    Logger.configure(level: prev)
    result
  end

  defp parse_seeds(nil), do: Runner.default_seeds()
  defp parse_seeds(s), do: s |> String.split(",") |> Enum.map(&String.to_integer/1)

  defp filter_entries(entries, nil), do: entries

  defp filter_entries(entries, only) do
    ids = MapSet.new(String.split(only, ","))
    Enum.filter(entries, &MapSet.member?(ids, &1.id))
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)

  defp git(cmd, args) do
    case System.cmd("git", [cmd | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  end
end

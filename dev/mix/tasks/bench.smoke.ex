defmodule Mix.Tasks.Bench.Smoke do
  @shortdoc "Fast always-on quality smoke: feasibility + gap-to-BKS ceiling on a small subset"

  @moduledoc """
  Runs a small, fast subset of the corpus single-ref and fails if any instance
  is infeasible or exceeds a generous gap-to-BKS ceiling. Intended to run on
  every CI push as a cheap quality guard; the labeled-PR A/B job is the precise
  gate.

      mix bench.smoke
      mix bench.smoke --budget 10 --ceiling 0.05

  Options:
    --budget   Per-instance budget in seconds (default: 10)
    --ceiling  Max allowed gap-to-BKS as a fraction (default: 0.08 = 8%)
  """
  use Mix.Task

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Runner
  alias ExVrp.ABBenchmark.Smoke

  require Logger

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [budget: :float, ceiling: :float])
    Application.ensure_all_started(:ex_vrp)

    budget = opts[:budget] || 10.0
    ceiling = opts[:ceiling] || 0.08
    entries = Enum.filter(Corpus.entries(), &(&1.id in Smoke.smoke_ids()))

    results =
      quiet(fn ->
        Runner.run(entries: entries, seeds: [1], budget_s: budget, ref: "smoke", commit: "smoke")
      end)

    print_table(results)
    violations = Smoke.violations(results, ceiling)

    if violations == [] do
      Mix.shell().info("\nQuality smoke passed (#{map_size(results["instances"])} instances).")
    else
      Enum.each(violations, fn v -> Mix.shell().error("SMOKE FAIL: #{v}") end)
      exit({:shutdown, 1})
    end
  end

  defp print_table(results) do
    Mix.shell().info("\nQuality smoke")

    for {id, inst} <- Enum.sort_by(results["instances"], fn {id, _} -> id end) do
      bks = inst["bks"]
      obj = inst["mean_objective"]

      gap =
        if is_number(bks) and is_number(obj) and bks > 0, do: "#{Float.round((obj - bks) / bks * 100, 2)}%", else: "n/a"

      Mix.shell().info("  #{String.pad_trailing(id, 16)} obj=#{obj} feasible=#{inst["feasible_count"]}/1 gap=#{gap}")
    end
  end

  defp quiet(fun) do
    prev = Logger.level()
    Logger.configure(level: :warning)
    result = fun.()
    Logger.configure(level: prev)
    result
  end
end

defmodule Mix.Tasks.Bench.Compare do
  @shortdoc "Compare two A/B benchmark results JSONs and exit non-zero on regression"

  @moduledoc """
  Compares a baseline results JSON against a candidate results JSON.

      mix bench.compare results-base.json results-head.json

  Exits with status 1 if a hard regression is detected.
  """
  use Mix.Task

  alias ExVrp.ABBenchmark.Comparator

  @requirements ["app.config"]

  @impl Mix.Task
  def run([baseline_path, candidate_path]) do
    Application.ensure_all_started(:ex_vrp)
    baseline = baseline_path |> File.read!() |> Jason.decode!()
    candidate = candidate_path |> File.read!() |> Jason.decode!()

    case Comparator.compare(baseline, candidate) do
      {:ok, _summary} -> :ok
      {:regression, _summary} -> exit({:shutdown, 1})
    end
  end

  def run(_args) do
    Mix.shell().error("Usage: mix bench.compare <baseline.json> <candidate.json>")
    exit({:shutdown, 2})
  end
end

defmodule Mix.Tasks.Bench.Compare do
  @shortdoc "Compare baseline and candidate A/B results and exit non-zero on regression"

  @moduledoc """
  Compares a baseline results JSON against a candidate results JSON and prints the
  verdict, then the per-instance tables.

      mix bench.compare results-base.json results-head.json
      mix bench.compare results-base.json results-head.json \\
        --speed-base speed-base.json --speed-head speed-head.json --markdown report.md

  Options:
    --speed-base, --speed-head  `mix bench.speed` results of each ref; give both or neither
    --markdown                  Also write the report as markdown, for a PR comment

  Exits with status 1 if a hard regression is detected.
  """
  use Mix.Task

  alias ExVrp.ABBenchmark.Comparator
  alias ExVrp.ABBenchmark.Report

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {parsed, positional, _} =
      OptionParser.parse(args, switches: [speed_base: :string, speed_head: :string, markdown: :string])

    compare(positional, parsed[:speed_base], parsed[:speed_head], parsed[:markdown])
  end

  defp compare([baseline_path, candidate_path], speed_base_path, speed_head_path, markdown_path)
       when is_nil(speed_base_path) == is_nil(speed_head_path) do
    {verdict, summary} =
      Comparator.compare(
        decoded(baseline_path),
        decoded(candidate_path),
        decoded(speed_base_path),
        decoded(speed_head_path)
      )

    IO.puts(Report.render(summary, :text))
    write_markdown(summary, markdown_path)
    exit_with(verdict)
  end

  defp compare(_positional, _speed_base_path, _speed_head_path, _markdown_path) do
    Mix.shell().error(
      "Usage: mix bench.compare <baseline.json> <candidate.json> " <>
        "[--speed-base <speed-base.json> --speed-head <speed-head.json>] [--markdown <report.md>]"
    )

    exit({:shutdown, 2})
  end

  defp decoded(nil), do: nil
  defp decoded(path), do: path |> File.read!() |> Jason.decode!()

  defp write_markdown(_summary, nil), do: :ok
  defp write_markdown(summary, path), do: File.write!(path, Report.render(summary, :markdown))

  defp exit_with(:ok), do: :ok
  defp exit_with(:regression), do: exit({:shutdown, 1})
end

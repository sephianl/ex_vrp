defmodule Mix.Tasks.Bench.Lit.Report do
  @shortdoc "Summarise a literature run: gaps per group, PyVRP comparison, gap over time"

  @moduledoc """
  Summarises the JSON-lines output of `mix bench.lit.run`.

      mix bench.lit.report literature-run.jsonl
      mix bench.lit.report run.jsonl --html report.html

  For each group: the mean gap to the source's best-known costs with its standard error,
  next to PyVRP's published gaps where the group follows PyVRP's protocol; the gap to the
  lowest known cost; best-of-seeds; how many proven optima were reached; and the mean gap
  at 10/25/50/100% of the budget.
  """
  use Mix.Task

  alias ExVrp.Literature.Gap
  alias ExVrp.Literature.GroupSummary
  alias ExVrp.Literature.HtmlReport

  @pyvrp_versions ["0.13.0", "0.14.0"]

  @impl Mix.Task
  def run(args) do
    {options, paths, _invalid} = OptionParser.parse(args, strict: [html: :string])
    records = Enum.flat_map(paths, &read_records/1)
    summaries = GroupSummary.from_records(records)

    print_summary_table(summaries)
    print_gap_over_budget(summaries)
    print_warnings(summaries, records)
    write_html(options[:html], summaries, records)
  end

  defp read_records(path), do: path |> File.stream!() |> Enum.map(&Jason.decode!/1)

  defp print_summary_table(summaries) do
    Mix.shell().info(
      "\n" <>
        row([
          "group",
          "inst",
          "seeds",
          "gap→BKS",
          "±se",
          "PyVRP 0.13",
          "vs 0.13",
          "PyVRP 0.14",
          "vs 0.14",
          "gap→best",
          "best-of",
          "optimum",
          "iter/s"
        ])
    )

    Enum.each(summaries, fn summary -> Mix.shell().info(summary_row(summary)) end)
  end

  defp summary_row(%GroupSummary{} = summary) do
    row(
      [
        Atom.to_string(summary.group.id),
        Integer.to_string(summary.instances),
        Integer.to_string(summary.seeds),
        Gap.format(summary.mean_gap_to_bks),
        format_standard_error(summary.standard_error)
      ] ++
        Enum.flat_map(@pyvrp_versions, &pyvrp_columns(summary, &1)) ++
        [
          Gap.format(summary.mean_gap_to_best_known),
          format_best_of_seeds(summary),
          "#{summary.optimum_reached}/#{summary.proven_optimal}",
          format_rate(summary.iterations_per_second)
        ]
    )
  end

  defp pyvrp_columns(%GroupSummary{group: %{pyvrp_published_gaps: nil}}, _version), do: ["—", ""]

  defp pyvrp_columns(%GroupSummary{group: group} = summary, version) do
    published = "#{group.pyvrp_published_gaps[version]}%"
    [published, format_comparison(GroupSummary.pyvrp_comparison(summary, version))]
  end

  defp format_comparison(nil), do: "n/a"
  defp format_comparison({:within_noise, _difference}), do: "≈ noise"
  defp format_comparison({verdict, difference}), do: "#{verdict} #{signed_points(difference)}"

  defp signed_points(difference) when difference >= 0, do: "+" <> Gap.format(difference)
  defp signed_points(difference), do: Gap.format(difference)

  defp format_standard_error(nil), do: "—"
  defp format_standard_error(standard_error), do: Gap.format(standard_error)

  defp format_best_of_seeds(%GroupSummary{seeds: 1}), do: "—"
  defp format_best_of_seeds(%GroupSummary{best_of_seeds_gap: gap}), do: Gap.format(gap)

  defp format_rate(nil), do: "—"
  defp format_rate(rate), do: rate |> round() |> Integer.to_string()

  defp print_gap_over_budget(summaries) do
    Mix.shell().info(
      "\nMean gap to best known at a fraction of the budget\n" <> row(["group", "10%", "25%", "50%", "100%"])
    )

    Enum.each(summaries, fn summary ->
      Mix.shell().info(
        row([Atom.to_string(summary.group.id) | Enum.map(summary.gap_over_budget, &format_gap_at_fraction/1)])
      )
    end)
  end

  defp format_gap_at_fraction({_fraction, nil = _no_feasible_solution_yet}), do: "—"
  defp format_gap_at_fraction({_fraction, gap}), do: Gap.format(gap)

  defp print_warnings(summaries, records) do
    Mix.shell().info("\nWorst instances per group")

    Enum.each(summaries, fn summary ->
      worst = Enum.map_join(summary.worst_instances, ", ", fn {name, gap} -> "#{name} #{Gap.format(gap)}" end)
      Mix.shell().info("  #{summary.group.id}: #{worst}")
    end)

    Mix.shell().info("\nSlowest instances per group (iterations/s, wall-clock under the run's load)")

    Enum.each(summaries, fn summary ->
      slowest =
        Enum.map_join(summary.slowest_instances, ", ", fn {name, num_clients, rate} ->
          "#{name} (n=#{num_clients}) #{format_rate(rate)}"
        end)

      Mix.shell().info("  #{summary.group.id}: #{slowest}")
    end)

    Enum.each(summaries, &warn_infeasible/1)
    records |> Enum.map(& &1["budget_scale"]) |> Enum.uniq() |> warn_budget_scale()
  end

  defp warn_infeasible(%GroupSummary{infeasible_solves: 0}), do: :ok

  defp warn_infeasible(%GroupSummary{} = summary) do
    Mix.shell().error(
      "#{summary.group.id}: #{summary.infeasible_solves} infeasible solves; " <>
        "no feasible solution at all on #{inspect(summary.unsolved_instances)}"
    )
  end

  defp warn_budget_scale([1.0]), do: :ok

  defp warn_budget_scale(scales) do
    Mix.shell().error("Budget scale #{inspect(scales)}: these gaps are not comparable with PyVRP's published ones.")
  end

  defp write_html(nil, _summaries, _records), do: :ok

  defp write_html(path, summaries, records) do
    File.write!(path, HtmlReport.render(summaries, records))
    Mix.shell().info("\nWrote #{path}")
  end

  defp row([first | rest]), do: String.pad_trailing(first, 10) <> Enum.map_join(rest, &String.pad_leading(&1, 14))
end

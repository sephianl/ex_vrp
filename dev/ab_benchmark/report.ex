defmodule ExVrp.ABBenchmark.Report do
  @moduledoc """
  Renders an `ExVrp.ABBenchmark.Comparator` summary so that it opens with the
  verdict: PASS or FAIL, every fail and warning, and the changes that are results,
  meaning beyond their noise. The per-instance tables follow; in `:markdown`, for the
  PR comment, they fold away under `<details>` because the verdict already says
  everything they show that matters.
  """

  alias ExVrp.ABBenchmark.Comparator
  alias ExVrp.ABBenchmark.SpeedComparison

  @spec render(Comparator.summary(), :text | :markdown) :: String.t()
  def render(summary, :text), do: Enum.join([verdict(summary), tables(summary)], "\n\n")

  def render(summary, :markdown) do
    """
    ### A/B Benchmark

    ```
    #{verdict(summary)}
    ```

    <details><summary>Per-instance tables</summary>

    ```
    #{tables(summary)}
    ```

    </details>
    """
  end

  defp verdict(%{hard_fails: hard_fails, warnings: warnings, results: results, speed_rows: speed_rows}) do
    [headline(hard_fails)]
    |> Kernel.++(Enum.map(hard_fails, &"FAIL: #{&1}"))
    |> Kernel.++(Enum.map(warnings, &"WARN: #{&1}"))
    |> Kernel.++(["", results_heading(results) | Enum.map(results, &"  #{&1}")])
    |> Kernel.++(speed_coverage(speed_rows))
    |> Enum.join("\n")
  end

  defp headline([]), do: "PASS"
  defp headline(_hard_fails), do: "FAIL"

  defp results_heading([]), do: "Nothing moved beyond its noise."
  defp results_heading(_results), do: "Changes beyond noise:"

  defp speed_coverage(:not_measured),
    do: ["", "Speed not measured: the comparison was given no `mix bench.speed` results."]

  defp speed_coverage(_speed_rows), do: []

  defp tables(%{objective_rows: objective_rows, speed_rows: speed_rows}),
    do: Enum.join([objective_table(objective_rows) | speed_table(speed_rows)], "\n\n")

  defp objective_table(rows) do
    header =
      "#{rpad("Instance", 34)} #{lpad("Base", 13)} #{lpad("Cand", 13)} #{lpad("Delta%", 9)} " <>
        "#{lpad("Noise", 8)} #{lpad("Gap b->c", 13)}"

    footer =
      "Objective, mean over seeds. Delta% marked * exceeds the spread of this instance's " <>
        "paired per-seed deltas; unmarked deltas are not results."

    table(header, Enum.map(rows, &objective_line/1), footer)
  end

  defp objective_line(r) do
    "#{rpad(r.id, 34)} #{lpad(fmt(r.baseline_mean), 13)} #{lpad(fmt(r.candidate_mean), 13)} " <>
      "#{lpad(fmt_pct(r.pct_change) <> significance_mark(r), 9)} #{lpad(fmt_pct(r.noise), 8)} " <>
      "#{lpad(fmt_gap_pair(r), 13)}"
  end

  defp speed_table(:not_measured), do: []

  defp speed_table(rows) do
    header = "#{rpad("Instance", 34)} #{lpad("Base M/it", 13)} #{lpad("Cand M/it", 13)} #{lpad("Delta%", 9)} Path"

    footer =
      "Speed, user-space instructions per search iteration (millions). Counts repeat within " <>
        "0.05%; Delta% beyond #{fmt_pct(SpeedComparison.result_threshold())} is a result."

    [table(header, Enum.map(rows, &speed_line/1), footer)]
  end

  defp speed_line(r) do
    "#{rpad(r.id, 34)} #{lpad(fmt(r.baseline_per_iteration / 1.0e6), 13)} " <>
      "#{lpad(fmt(r.candidate_per_iteration / 1.0e6), 13)} #{lpad(fmt_pct(r.pct_change), 9)} " <>
      path_label(r.path_changed)
  end

  defp path_label(true), do: "changed"
  defp path_label(false), do: "same"

  defp table(header, lines, footer) do
    divider = String.duplicate("-", String.length(header))
    Enum.join([divider, header, divider] ++ lines ++ [divider, footer], "\n")
  end

  defp significance_mark(row), do: row |> Comparator.significant?() |> mark()

  defp mark(true), do: "*"
  defp mark(false), do: ""

  defp fmt_gap_pair(%{baseline_gap: nil, candidate_gap: nil}), do: "n/a"
  defp fmt_gap_pair(r), do: "#{fmt_pct(r.baseline_gap)}->#{fmt_pct(r.candidate_gap)}"

  defp fmt(nil), do: "n/a"
  defp fmt(x), do: :erlang.float_to_binary(x, decimals: 1)
  defp fmt_pct(nil), do: "n/a"
  defp fmt_pct(x), do: "#{Float.round(x * 100, 2)}%"
  defp rpad(s, w), do: s |> to_string() |> String.slice(0, w) |> String.pad_trailing(w)
  defp lpad(s, w), do: String.pad_leading(to_string(s), w)
end

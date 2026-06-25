defmodule ExVrp.ABBenchmark.Comparator do
  @moduledoc """
  Compares two benchmark results maps (baseline ref vs candidate ref) and
  decides whether the candidate regressed solution quality.
  """

  defmodule Row do
    @moduledoc false
    @type t :: %__MODULE__{
            id: term(),
            variant: term(),
            bks: number() | nil,
            baseline_mean: float() | nil,
            candidate_mean: float() | nil,
            baseline_feasible: non_neg_integer(),
            candidate_feasible: non_neg_integer(),
            baseline_gap: float() | nil,
            candidate_gap: float() | nil,
            pct_change: float() | nil
          }
    defstruct [
      :id,
      :variant,
      :bks,
      :baseline_mean,
      :candidate_mean,
      :baseline_feasible,
      :candidate_feasible,
      :baseline_gap,
      :candidate_gap,
      :pct_change
    ]
  end

  @spec analyze(map(), map()) :: %{per_instance: [Row.t()], missing: [String.t()]}
  def analyze(baseline, candidate) do
    base_inst = baseline["instances"]
    cand_inst = candidate["instances"]

    base_ids = Map.keys(base_inst)
    common = base_ids |> Enum.filter(&Map.has_key?(cand_inst, &1)) |> Enum.sort()
    missing = base_ids |> Enum.reject(&Map.has_key?(cand_inst, &1)) |> Enum.sort()

    rows = Enum.map(common, fn id -> build_row(id, base_inst[id], cand_inst[id]) end)
    %{per_instance: rows, missing: missing}
  end

  defp build_row(id, base, cand) do
    bks = base["bks"]
    base_mean = mean_feasible(base["seeds"])
    cand_mean = mean_feasible(cand["seeds"])

    %Row{
      id: id,
      variant: base["variant"],
      bks: bks,
      baseline_mean: base_mean,
      candidate_mean: cand_mean,
      baseline_feasible: feasible_count(base["seeds"]),
      candidate_feasible: feasible_count(cand["seeds"]),
      baseline_gap: gap(base_mean, bks),
      candidate_gap: gap(cand_mean, bks),
      pct_change: pct_change(base_mean, cand_mean)
    }
  end

  defp mean_feasible(seeds) do
    objs = for {_s, m} <- seeds, m["feasible"], do: m["objective"]

    case objs do
      [] -> nil
      list -> Enum.sum(list) / length(list)
    end
  end

  defp feasible_count(seeds), do: Enum.count(seeds, fn {_s, m} -> m["feasible"] end)

  defp gap(_mean, nil), do: nil
  defp gap(nil, _bks), do: nil
  defp gap(mean, bks) when bks > 0, do: (mean - bks) / bks
  defp gap(_mean, _bks), do: nil

  defp pct_change(nil, _cand), do: nil
  defp pct_change(_base, nil), do: nil
  defp pct_change(base, cand) when base > 0, do: (cand - base) / base
  defp pct_change(_base, _cand), do: nil

  @objective_pct_threshold 0.005
  @warn_pct_threshold 0.01

  @spec compare(map(), map()) ::
          {:ok | :regression, %{hard_fails: [String.t()], warnings: [String.t()]}}
  def compare(baseline, candidate) do
    %{per_instance: rows, missing: missing} = analyze(baseline, candidate)

    hard_fails =
      infeasibility_fails(rows) ++ missing_fails(missing) ++ aggregate_objective_fail(rows)

    warnings = localized_warnings(rows)

    print_report(rows, hard_fails, warnings)

    summary = %{hard_fails: hard_fails, warnings: warnings}
    if hard_fails == [], do: {:ok, summary}, else: {:regression, summary}
  end

  defp infeasibility_fails(rows) do
    for r <- rows, r.baseline_feasible > 0 and r.candidate_feasible == 0 do
      "#{r.id}: regressed to infeasible (baseline #{r.baseline_feasible} feasible seeds, candidate 0)"
    end
  end

  defp missing_fails(missing) do
    for id <- missing do
      "#{id}: present in baseline but missing from candidate (did the candidate crash on it?)"
    end
  end

  defp aggregate_objective_fail(rows) do
    changed = Enum.filter(rows, &(&1.pct_change != nil))

    case changed do
      [] ->
        []

      _ ->
        avg_pct = avg(Enum.map(changed, & &1.pct_change))

        if avg_pct > @objective_pct_threshold do
          ["aggregate objective worsened by #{Float.round(avg_pct * 100, 3)}% vs baseline (> 0.5%)"]
        else
          []
        end
    end
  end

  defp localized_warnings(rows) do
    for r <- rows, r.pct_change != nil and r.pct_change > @warn_pct_threshold do
      "#{r.id}: objective worsened #{Float.round(r.pct_change * 100, 2)}% (warn threshold 1%)"
    end
  end

  defp avg([]), do: 0.0
  defp avg(list), do: Enum.sum(list) / length(list)

  defp print_report(rows, hard_fails, warnings) do
    divider = String.duplicate("-", 88)
    IO.puts("\nA/B Benchmark Comparison")
    IO.puts(divider)

    IO.puts(
      "#{rpad("Instance", 28)} #{lpad("Base", 12)} #{lpad("Cand", 12)} #{lpad("Delta%", 9)} #{lpad("Base gap", 10)} #{lpad("Cand gap", 10)}"
    )

    IO.puts(divider)
    Enum.each(rows, &print_row/1)
    IO.puts(divider)
    Enum.each(warnings, fn w -> IO.puts("WARN: #{w}") end)
    Enum.each(hard_fails, fn f -> IO.puts("FAIL: #{f}") end)
    IO.puts(if hard_fails == [], do: "\nNo regressions detected.\n", else: "\nREGRESSION DETECTED.\n")
  end

  defp print_row(r) do
    IO.puts(
      "#{rpad(r.id, 28)} #{lpad(fmt(r.baseline_mean), 12)} #{lpad(fmt(r.candidate_mean), 12)} " <>
        "#{lpad(fmt_pct(r.pct_change), 9)} #{lpad(fmt_gap(r.baseline_gap), 10)} #{lpad(fmt_gap(r.candidate_gap), 10)}"
    )
  end

  defp fmt(nil), do: "n/a"
  defp fmt(x), do: :erlang.float_to_binary(x, decimals: 1)
  defp fmt_pct(nil), do: "n/a"
  defp fmt_pct(x), do: "#{Float.round(x * 100, 2)}%"
  defp fmt_gap(nil), do: "n/a"
  defp fmt_gap(x), do: "#{Float.round(x * 100, 2)}%"
  defp rpad(s, w), do: String.pad_trailing(to_string(s), w)
  defp lpad(s, w), do: String.pad_leading(to_string(s), w)
end

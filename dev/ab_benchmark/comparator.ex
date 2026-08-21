defmodule ExVrp.ABBenchmark.Comparator do
  @moduledoc """
  Compares two benchmark results maps (baseline ref vs candidate ref) and
  decides whether the candidate regressed solution quality.

  Solves stop on wall-clock, so the same seed on the same code does not reproduce
  exactly: instances that converge inside their budget land on identical solutions
  and instances that do not, scatter. Every row therefore carries a `noise` band —
  the widest seed-to-seed spread of the two refs — and a `pct_change` inside that
  band is not a result. Warnings respect the band so an instance can never be
  flagged for moving less than it moves against itself.
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
            pct_change: float() | nil,
            noise: float() | nil,
            iter_pct_change: float() | nil
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
      :pct_change,
      :noise,
      :iter_pct_change
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
    base_objs = feasible_objectives(base["seeds"])
    cand_objs = feasible_objectives(cand["seeds"])
    base_mean = mean(base_objs)
    cand_mean = mean(cand_objs)

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
      pct_change: pct_change(base_mean, cand_mean),
      noise: widest(spread(base_objs), spread(cand_objs)),
      iter_pct_change: pct_change(mean_iterations(base["seeds"]), mean_iterations(cand["seeds"]))
    }
  end

  defp feasible_objectives(seeds), do: for({_s, m} <- seeds, m["feasible"], do: m["objective"])

  defp mean_iterations(seeds), do: mean(for {_s, m} <- seeds, m["feasible"], do: m["iterations"] || 0)

  defp mean([]), do: nil
  defp mean(list), do: Enum.sum(list) / length(list)

  defp spread([]), do: nil
  defp spread([_single]), do: 0.0

  defp spread(objs) do
    {low, high} = Enum.min_max(objs)
    relative_range(high - low, mean(objs))
  end

  defp relative_range(_range, mean) when mean <= 0, do: nil
  defp relative_range(range, mean), do: range / mean

  defp widest(nil, other), do: other
  defp widest(one, nil), do: one
  defp widest(one, other), do: max(one, other)

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
        avg_pct = mean(Enum.map(changed, & &1.pct_change))

        if avg_pct > @objective_pct_threshold do
          ["aggregate objective worsened by #{Float.round(avg_pct * 100, 3)}% vs baseline (> 0.5%)"]
        else
          []
        end
    end
  end

  defp localized_warnings(rows) do
    for r <- rows, warnable?(r) do
      "#{r.id}: objective worsened #{Float.round(r.pct_change * 100, 2)}% " <>
        "(threshold #{Float.round(warn_floor(r) * 100, 2)}%, the greater of 1% and this instance's #{fmt_pct(r.noise)} noise)"
    end
  end

  defp warnable?(%Row{pct_change: nil}), do: false
  defp warnable?(r), do: r.pct_change > warn_floor(r)

  defp warn_floor(%Row{noise: nil}), do: @warn_pct_threshold
  defp warn_floor(%Row{noise: noise}), do: max(@warn_pct_threshold, noise)

  defp print_report(rows, hard_fails, warnings) do
    divider = String.duplicate("-", 104)
    IO.puts("\nA/B Benchmark Comparison")
    IO.puts(divider)

    IO.puts(
      "#{rpad("Instance", 34)} #{lpad("Base", 13)} #{lpad("Cand", 13)} #{lpad("Delta%", 9)} " <>
        "#{lpad("Noise", 8)} #{lpad("Iter%", 8)} #{lpad("Gap b->c", 13)}"
    )

    IO.puts(divider)
    Enum.each(rows, &print_row/1)
    IO.puts(divider)
    IO.puts("Delta% marked * exceeds this instance's seed-to-seed noise; unmarked deltas are not results.")
    Enum.each(warnings, fn w -> IO.puts("WARN: #{w}") end)
    Enum.each(hard_fails, fn f -> IO.puts("FAIL: #{f}") end)
    IO.puts(if hard_fails == [], do: "\nNo regressions detected.\n", else: "\nREGRESSION DETECTED.\n")
  end

  defp print_row(r) do
    IO.puts(
      "#{rpad(r.id, 34)} #{lpad(fmt(r.baseline_mean), 13)} #{lpad(fmt(r.candidate_mean), 13)} " <>
        "#{lpad(fmt_pct(r.pct_change) <> significance(r), 9)} #{lpad(fmt_pct(r.noise), 8)} " <>
        "#{lpad(fmt_pct(r.iter_pct_change), 8)} #{lpad(fmt_gap_pair(r), 13)}"
    )
  end

  defp significance(%Row{pct_change: nil}), do: ""
  defp significance(%Row{noise: nil}), do: ""
  defp significance(r), do: if(abs(r.pct_change) > r.noise, do: "*", else: "")

  defp fmt_gap_pair(%Row{baseline_gap: nil, candidate_gap: nil}), do: "n/a"
  defp fmt_gap_pair(r), do: "#{fmt_gap(r.baseline_gap)}->#{fmt_gap(r.candidate_gap)}"

  defp fmt(nil), do: "n/a"
  defp fmt(x), do: :erlang.float_to_binary(x, decimals: 1)
  defp fmt_pct(nil), do: "n/a"
  defp fmt_pct(x), do: "#{Float.round(x * 100, 2)}%"
  defp fmt_gap(nil), do: "n/a"
  defp fmt_gap(x), do: "#{Float.round(x * 100, 2)}%"
  defp rpad(s, w), do: s |> to_string() |> String.slice(0, w) |> String.pad_trailing(w)
  defp lpad(s, w), do: String.pad_leading(to_string(s), w)
end

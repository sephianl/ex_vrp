defmodule ExVrp.ABBenchmark.Comparator do
  @moduledoc """
  Compares a baseline ref against a candidate ref and decides whether the candidate
  regressed: in solution quality from two `ExVrp.ABBenchmark.Runner` results, and in
  speed from two `ExVrp.ABBenchmark.Speed` results via
  `ExVrp.ABBenchmark.SpeedComparison`.

  Solves stop on wall-clock, so the same seed on the same code does not reproduce
  exactly: instances that converge inside their budget land on identical solutions
  and instances that do not, scatter. Every row therefore carries a `noise` band,
  and a `pct_change` inside that band is not a result. Warnings respect the band so
  an instance can never be flagged for moving less than it moves against itself.

  Both refs run the same seed set, so the band is computed from the *paired*
  per-seed deltas rather than from the scatter of raw objectives. Seeds differ from
  each other far more than a code change moves any one of them, and that difference
  is common to both refs, so it cancels in the pairing. Banding on raw scatter
  instead charges a code change for variance it did not cause, which hides real
  effects on exactly the instances that scatter most.
  """

  alias ExVrp.ABBenchmark.SpeedComparison

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
            noise: float() | nil
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
      :noise
    ]
  end

  @type summary :: %{
          hard_fails: [String.t()],
          warnings: [String.t()],
          results: [String.t()],
          objective_rows: [Row.t()],
          speed_rows: [SpeedComparison.Row.t()] | :not_measured
        }

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

  @doc """
  Compares quality and, unless both speed results are `nil` (the speed job did not
  run), speed. Fails on any hard fail of either.
  """
  @spec compare(map(), map(), map() | nil, map() | nil) :: {:ok | :regression, summary()}
  def compare(baseline, candidate, speed_baseline, speed_candidate) do
    %{per_instance: rows, missing: missing} = analyze(baseline, candidate)
    speed = analyze_speed(speed_baseline, speed_candidate)

    hard_fails =
      infeasibility_fails(rows) ++
        missing_fails(missing) ++
        aggregate_objective_fail(rows) ++
        speed_hard_fails(speed)

    summary = %{
      hard_fails: hard_fails,
      warnings: localized_warnings(rows) ++ speed_warnings(speed),
      results: objective_results(rows) ++ speed_results(speed),
      objective_rows: rows,
      speed_rows: speed_rows(speed)
    }

    {verdict(hard_fails), summary}
  end

  @spec significant?(Row.t()) :: boolean()
  def significant?(%Row{pct_change: nil}), do: false
  def significant?(%Row{noise: nil}), do: false
  def significant?(%Row{pct_change: pct, noise: noise}), do: abs(pct) > noise

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
      noise: paired_noise(paired_deltas(base["seeds"], cand["seeds"]))
    }
  end

  defp feasible_objectives(seeds), do: for({_s, m} <- seeds, m["feasible"], do: m["objective"])

  defp mean([]), do: nil
  defp mean(list), do: Enum.sum(list) / length(list)

  defp paired_deltas(base_seeds, cand_seeds) do
    cand_seeds = Map.new(cand_seeds)

    for {seed, b} <- base_seeds,
        c = Map.get(cand_seeds, seed),
        paired_feasible?(b, c),
        do: (c["objective"] - b["objective"]) / b["objective"]
  end

  defp paired_feasible?(%{"feasible" => true, "objective" => base}, %{"feasible" => true, "objective" => cand})
       when is_number(base) and base > 0 and is_number(cand), do: true

  defp paired_feasible?(_base, _cand), do: false

  defp paired_noise([]), do: nil
  defp paired_noise([_single]), do: 0.0

  defp paired_noise(deltas) do
    {low, high} = Enum.min_max(deltas)
    high - low
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

  defp analyze_speed(nil, nil), do: :not_measured
  defp analyze_speed(speed_baseline, speed_candidate), do: SpeedComparison.analyze(speed_baseline, speed_candidate)

  defp speed_hard_fails(:not_measured), do: []
  defp speed_hard_fails(speed), do: SpeedComparison.hard_fails(speed)

  defp speed_warnings(:not_measured), do: []
  defp speed_warnings(%{rows: rows}), do: SpeedComparison.warnings(rows)

  defp speed_results(:not_measured), do: []
  defp speed_results(%{rows: rows}), do: SpeedComparison.results(rows)

  defp speed_rows(:not_measured), do: :not_measured
  defp speed_rows(%{rows: rows}), do: rows

  defp verdict([]), do: :ok
  defp verdict(_hard_fails), do: :regression

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
    rows
    |> Enum.map(& &1.pct_change)
    |> Enum.reject(&is_nil/1)
    |> mean()
    |> aggregate_objective_verdict()
  end

  defp aggregate_objective_verdict(avg_pct) when is_float(avg_pct) and avg_pct > @objective_pct_threshold,
    do: ["aggregate objective worsened by #{Float.round(avg_pct * 100, 3)}% vs baseline (> 0.5%)"]

  defp aggregate_objective_verdict(_avg_pct), do: []

  defp localized_warnings(rows) do
    for r <- rows, warnable?(r) do
      "#{r.id}: objective worsened #{Float.round(r.pct_change * 100, 2)}% " <>
        "(threshold #{Float.round(warn_floor(r) * 100, 2)}%, the greater of 1% and this instance's #{fmt_pct(r.noise)} noise)"
    end
  end

  defp objective_results(rows) do
    for r <- rows, significant?(r) do
      "#{r.id}: objective #{fmt_pct(r.pct_change)} (beyond its #{fmt_pct(r.noise)} noise)"
    end
  end

  defp warnable?(%Row{pct_change: nil}), do: false
  defp warnable?(r), do: r.pct_change > warn_floor(r)

  defp warn_floor(%Row{noise: nil}), do: @warn_pct_threshold
  defp warn_floor(%Row{noise: noise}), do: max(@warn_pct_threshold, noise)

  defp fmt_pct(x), do: "#{Float.round(x * 100, 2)}%"
end

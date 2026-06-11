defmodule ExVrp.ABBenchmark.Smoke do
  @moduledoc """
  Always-on quality smoke check. Runs a small fast subset single-ref (no A/B
  baseline) and flags violations: any infeasible instance, or any instance whose
  gap to its best-known objective exceeds a generous ceiling. Catches gross
  quality regressions and crashes on every CI run; the on-demand A/B job remains
  the precise quality gate.
  """

  @smoke_ids ~w(ok_small e_n22_k4 vrptw_R101 mtr_C201R0.5 mtr_R204R0.25)

  @spec smoke_ids() :: [String.t()]
  def smoke_ids, do: @smoke_ids

  @spec violations(map(), float()) :: [String.t()]
  def violations(results, gap_ceiling) do
    results["instances"]
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.flat_map(fn {id, inst} -> instance_violations(id, inst, gap_ceiling) end)
  end

  defp instance_violations(id, inst, gap_ceiling) do
    feasibility_violation(id, inst) ++ gap_violation(id, inst, gap_ceiling)
  end

  defp feasibility_violation(id, %{"feasible_count" => 0}), do: ["#{id}: no feasible solution"]
  defp feasibility_violation(_id, _inst), do: []

  defp gap_violation(id, %{"bks" => bks, "mean_objective" => obj}, gap_ceiling)
       when is_number(bks) and is_number(obj) and bks > 0 do
    gap = (obj - bks) / bks

    if gap > gap_ceiling do
      ["#{id}: gap-to-BKS #{Float.round(gap * 100, 2)}% exceeds ceiling #{Float.round(gap_ceiling * 100, 2)}%"]
    else
      []
    end
  end

  defp gap_violation(_id, _inst, _ceiling), do: []
end

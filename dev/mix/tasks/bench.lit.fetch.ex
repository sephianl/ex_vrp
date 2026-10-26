defmodule Mix.Tasks.Bench.Lit.Fetch do
  @shortdoc "Download the literature benchmark instances and build their manifest"

  @moduledoc """
  Downloads the instances `mix bench.lit.run` solves (PyVRP/Instances at a pinned commit and
  CVRPLib's DIMACS, Solomon and Homberger–Gehring sets) into
  `priv/benchmark_data/literature/`, refreshes CVRPLib's upper bounds, and checks every
  best-known solution against our model. Needs `7z` on the PATH.

      mix bench.lit.fetch

  Fails when a best-known solution is infeasible on our model or its cost disagrees with
  its source, since gaps on such an instance would not mean anything.
  """
  use Mix.Task

  alias ExVrp.Literature.BenchmarkInstance
  alias ExVrp.Literature.Fetch

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:ex_vrp)
    Logger.configure(level: :warning)

    case Fetch.run() do
      {:ok, instances, problems} -> report(instances, problems)
      {:error, reason} -> Mix.raise("Fetch failed: #{reason}")
    end
  end

  defp report(instances, problems) do
    Mix.shell().info("\nGroup        instances  proven optimal  newer CVRPLib bound")

    instances
    |> Enum.group_by(& &1.group)
    |> Enum.each(fn {group, group_instances} -> Mix.shell().info(group_line(group, group_instances)) end)

    report_problems(problems)
  end

  defp group_line(group, instances) do
    optimal = Enum.count(instances, & &1.optimal)
    newer_bound = Enum.count(instances, &(BenchmarkInstance.best_known(&1) < &1.bks))

    String.pad_trailing(to_string(group), 13) <>
      String.pad_leading(to_string(length(instances)), 9) <>
      String.pad_leading(to_string(optimal), 16) <> String.pad_leading(to_string(newer_bound), 21)
  end

  defp report_problems([]), do: Mix.shell().info("\nEvery best-known solution checks out on our model.")

  defp report_problems(problems) do
    Enum.each(problems, &Mix.shell().error("PROBLEM #{&1}"))
    exit({:shutdown, 1})
  end
end

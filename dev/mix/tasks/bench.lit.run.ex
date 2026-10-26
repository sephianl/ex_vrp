defmodule Mix.Tasks.Bench.Lit.Run do
  @shortdoc "Solve the literature benchmark instances and record gaps to best-known costs"

  @moduledoc """
  Solves the instances `mix bench.lit.fetch` downloaded, one single-start solve per
  instance and seed, each on one core, and appends one JSON line per solve to `--out`.
  Rerunning with the same `--out` resumes where the last run stopped.

      mix bench.lit.run --passmark 4200
      mix bench.lit.run --groups cvrp,solomon --seeds 1,2 --out cvrp.jsonl
      mix bench.lit.run --budget-scale 0.02 --limit 2

  Options:
    --passmark      Single-thread PassMark score of this machine. Budgets follow PyVRP's
                    protocol and scale by reference/passmark (default: the reference, i.e.
                    the longest budgets). Look the CPU up on cpubenchmark.net.
    --budget-scale  Multiplies every budget, for quick checks (default: 1). Results at any
                    other scale are not comparable with PyVRP's published numbers.
    --subset        `sample` (default, the stratified sample) or `full`.
    --groups        Comma-separated groups (default: all): #{Enum.map_join(ExVrp.Literature.BenchmarkGroup.all(), ",", & &1.id)}.
    --seeds         Comma-separated seeds (default: 1). With K seeds the report also shows
                    best-of-K, which is what `num_starts: K` returns.
    --limit         At most this many instances per group.
    --workers       Concurrent solves (default: the dirty CPU schedulers).
    --out           Output file (default: literature-run.jsonl).
  """
  use Mix.Task

  alias ExVrp.Literature.BenchmarkGroup
  alias ExVrp.Literature.Manifest
  alias ExVrp.Literature.Runner
  alias ExVrp.Literature.RunSettings
  alias ExVrp.Literature.Sample

  @requirements ["app.config"]

  @switches [
    passmark: :integer,
    budget_scale: :float,
    subset: :string,
    groups: :string,
    seeds: :string,
    limit: :integer,
    workers: :integer,
    out: :string
  ]

  @impl Mix.Task
  def run(args) do
    {options, _rest, _invalid} = OptionParser.parse(args, strict: @switches)
    Application.ensure_all_started(:ex_vrp)
    Logger.configure(level: :error)

    settings = settings(options)

    with {:ok, instances} <- Manifest.read(),
         :ok <- Runner.run(selected_instances(instances, options), settings) do
      Mix.shell().info("Done. Report with: mix bench.lit.report #{settings.out_path}")
    else
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp settings(options) do
    %RunSettings{
      seeds: options |> Keyword.get(:seeds, "1") |> parse_integers(),
      passmark: options[:passmark] || warn_reference_passmark(),
      budget_scale: Keyword.get(options, :budget_scale, 1.0),
      out_path: Keyword.get(options, :out, "literature-run.jsonl"),
      workers: options[:workers] || :erlang.system_info(:dirty_cpu_schedulers_online)
    }
  end

  defp warn_reference_passmark do
    Mix.shell().info("No --passmark given: using the reference scores, which gives the longest budgets.")
    nil
  end

  defp selected_instances(instances, options) do
    groups = options |> Keyword.get(:groups) |> selected_groups()
    in_subset? = subset_filter(Keyword.get(options, :subset, "sample"))

    instances
    |> Enum.filter(&(&1.group in groups and in_subset?.(&1)))
    |> Enum.group_by(& &1.group)
    |> Enum.flat_map(fn {_group, group_instances} ->
      Enum.take(group_instances, options[:limit] || length(group_instances))
    end)
  end

  defp selected_groups(nil), do: Enum.map(BenchmarkGroup.all(), & &1.id)

  defp selected_groups(names) do
    names
    |> String.split(",", trim: true)
    |> Enum.map(&group_id/1)
  end

  defp group_id(name) do
    case BenchmarkGroup.id_from_name(name) do
      {:ok, id} -> id
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp subset_filter("sample"), do: &Sample.member?(&1.group, &1.name)
  defp subset_filter("full"), do: fn _instance -> true end
  defp subset_filter(other), do: Mix.raise("--subset must be sample or full, got #{other}")

  defp parse_integers(text), do: text |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1)
end

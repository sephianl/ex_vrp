defmodule ExVrp.Literature.Runner do
  @moduledoc """
  Solves literature instances, one single-start solve per (instance, seed) on one core,
  and appends each result to a JSON-lines file as soon as it finishes. A rerun with the
  same file skips what is already there, so a long run survives an interruption.

  The longest solves start first, so the run does not end on one long solve while every
  other core idles. Each record carries the solve's convergence trace: every improvement
  of the best feasible cost as `[elapsed_ms, cost]`.
  """

  alias ExVrp.ABBenchmark.Checkout
  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Loader
  alias ExVrp.ABBenchmark.Solve
  alias ExVrp.Literature.BenchmarkGroup
  alias ExVrp.Literature.BenchmarkInstance
  alias ExVrp.Literature.Gap
  alias ExVrp.Literature.Manifest
  alias ExVrp.Literature.ProgressBoard
  alias ExVrp.Literature.RunSettings

  @spec run([BenchmarkInstance.t()], RunSettings.t()) :: :ok | {:error, String.t()}
  def run(instances, %RunSettings{} = settings) do
    with {:ok, completed} <- completed_jobs(settings) do
      jobs =
        for instance <- instances,
            seed <- settings.seeds,
            not MapSet.member?(completed, {instance.name, seed}),
            do: {instance, seed, budget_seconds(instance, settings)}

      run_jobs(
        Enum.sort_by(jobs, fn {_instance, _seed, budget_s} -> budget_s end, :desc),
        settings,
        MapSet.size(completed)
      )
    end
  end

  defp run_jobs(jobs, settings, already_completed) do
    Mix.shell().info(estimate(jobs, settings.workers, already_completed))
    {:ok, board} = ProgressBoard.start_link(length(jobs))
    machine = machine_description(settings)

    jobs
    |> Task.async_stream(&run_job(&1, board, machine),
      max_concurrency: settings.workers,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.each(fn {:ok, record} -> append_record(settings.out_path, record) end)
  end

  defp append_record(out_path, record), do: File.write!(out_path, [Jason.encode!(record), "\n"], [:append])

  defp budget_seconds(%BenchmarkInstance{num_clients: num_clients} = instance, settings) do
    instance
    |> BenchmarkInstance.group()
    |> BenchmarkGroup.budget_seconds(num_clients, settings.passmark, settings.budget_scale)
  end

  defp run_job({instance, seed, budget_s}, board, machine) do
    job_label = "#{instance.group} #{instance.name} seed #{seed}"
    best_known = BenchmarkInstance.best_known(instance)
    on_progress = progress_reporter(self(), board, job_label, budget_s, best_known)

    solve_record = solve(instance, budget_s, seed, on_progress)
    trace = collect_trace(solve_record)
    ProgressBoard.finished(board, job_label, Gap.format(Gap.of(solve_record["objective"], best_known)))

    solve_record
    |> Map.merge(machine)
    |> Map.merge(%{
      "instance" => instance.name,
      "group" => instance.group,
      "num_clients" => instance.num_clients,
      "seed" => seed,
      "budget_s" => budget_s,
      "bks" => instance.bks,
      "best_known" => best_known,
      "optimal" => instance.optimal,
      "trace" => trace
    })
  end

  defp solve(instance, budget_s, seed, on_progress) do
    entry = %Corpus.Entry{
      id: instance.name,
      variant: instance.group,
      kind: :vrplib,
      path: Manifest.absolute_path(instance),
      round_func: BenchmarkInstance.group(instance).round_func
    }

    entry |> Loader.load() |> Solve.solve(budget_s, seed, on_progress)
  end

  defp progress_reporter(job, board, job_label, budget_s, best_known) do
    fn
      %{elapsed_ms: elapsed_ms, best_cost: best_cost} ->
        send(job, {:trace_point, elapsed_ms, best_cost})

        ProgressBoard.progress(board, job_label, %{
          elapsed_s: elapsed_ms / 1000,
          budget_s: budget_s,
          gap: Gap.of(best_cost, best_known)
        })

      %{stage: _setup_stage} ->
        :ok
    end
  end

  defp collect_trace(%{"objective" => objective, "time_ms" => time_ms}) do
    [[time_ms, objective] | drain_trace_points([])]
    |> Enum.reverse()
    |> Enum.filter(fn [_elapsed_ms, cost] -> is_number(cost) end)
    |> Enum.dedup_by(fn [_elapsed_ms, cost] -> cost end)
  end

  defp drain_trace_points(points) do
    receive do
      {:trace_point, elapsed_ms, cost} -> drain_trace_points([[elapsed_ms, cost] | points])
    after
      0 -> points
    end
  end

  defp completed_jobs(%RunSettings{out_path: out_path} = settings) do
    out_path
    |> File.exists?()
    |> completed_records(out_path)
    |> check_same_settings(settings)
  end

  defp completed_records(false = _exists, _out_path), do: []

  defp completed_records(true = _exists, out_path) do
    out_path |> File.stream!() |> Enum.map(&Jason.decode!/1)
  end

  defp check_same_settings(records, %RunSettings{passmark: passmark, budget_scale: budget_scale}) do
    records
    |> Enum.all?(&(&1["passmark"] == passmark and &1["budget_scale"] == budget_scale))
    |> completed_or_mismatch(records)
  end

  defp completed_or_mismatch(true = _same_settings, records),
    do: {:ok, MapSet.new(records, &{&1["instance"], &1["seed"]})}

  defp completed_or_mismatch(false = _same_settings, _records),
    do: {:error, "the output file holds results with another --passmark or --budget-scale; use a new --out"}

  defp estimate(jobs, workers, already_completed) do
    cpu_s = Enum.sum_by(jobs, fn {_instance, _seed, budget_s} -> budget_s end)
    longest_s = jobs |> Enum.map(fn {_instance, _seed, budget_s} -> budget_s end) |> Enum.max(fn -> 0 end)
    wall_s = max(cpu_s / workers, longest_s)

    "#{length(jobs)} solves to run (#{already_completed} already done) on #{workers} cores: " <>
      "#{Float.round(cpu_s / 3600, 1)} CPU-h, about #{Float.round(wall_s / 3600, 1)} h wall-clock"
  end

  defp machine_description(settings) do
    %{
      "passmark" => settings.passmark,
      "budget_scale" => settings.budget_scale,
      "commit" => Checkout.commit(),
      "cpu" => cpu_model(File.read("/proc/cpuinfo")),
      "cores" => System.schedulers_online()
    }
  end

  defp cpu_model({:ok, cpuinfo}) do
    ~r/^model name\s*:\s*(.+)$/m
    |> Regex.run(cpuinfo)
    |> cpu_model_name()
  end

  defp cpu_model({:error, _no_proc_cpuinfo}), do: cpu_model_name(nil)

  defp cpu_model_name([_line, model]), do: model
  defp cpu_model_name(nil = _no_model_line), do: to_string(:erlang.system_info(:system_architecture))
end

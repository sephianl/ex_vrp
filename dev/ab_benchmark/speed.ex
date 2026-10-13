defmodule ExVrp.ABBenchmark.Speed do
  @moduledoc """
  Measures the solver's speed as user-space CPU instructions per search iteration.

  Unlike iterations within a wall-clock budget, an instruction count does not depend
  on what else the machine runs, so two refs measured on one machine differ only by
  what their code does. It needs hardware performance counters, which GitHub-hosted
  runners do not expose, so the A/B runs this on the self-hosted fleet.

  Every instance solves in a fresh BEAM under `perf stat`, once for `n` iterations
  and once for `3n`. The difference over `2n` iterations drops boot, compilation and
  instance loading, which a single count would mix into the solver's.
  """

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Loader
  alias ExVrp.ABBenchmark.SpeedMeasurementError
  alias ExVrp.StoppingCriteria

  @corpus [
    {"pc_R1_10_4", 200},
    {"pc_RC1_10_4", 200},
    {"cvrp_X-n439-k37", 400},
    {"c201", 600},
    {"mtr_R204R0.25", 400},
    {"prod_oban-966284", 150},
    {"prodbrk_oban-966207", 50}
  ]

  @idle_schedulers_sleep "+sbwt none +sbwtdcpu none +sbwtdio none"
  @solve_marker "BENCH_SPEED"

  @spec corpus() :: [{String.t(), pos_integer()}]
  def corpus, do: @corpus

  @spec run([{String.t(), pos_integer()}], String.t(), String.t()) :: map()
  def run(corpus, ref, commit) do
    %{
      "ref" => ref,
      "commit" => commit,
      "instances" => Map.new(corpus, fn {id, iterations} -> {id, measure(id, iterations)} end)
    }
  end

  @spec measure(String.t(), pos_integer()) :: map()
  def measure(id, iterations) do
    {short_instructions, short_distance} = count_solve(id, iterations)
    {long_instructions, long_distance} = count_solve(id, 3 * iterations)

    %{
      "iterations" => [iterations, 3 * iterations],
      "distances" => [short_distance, long_distance],
      "instructions_per_iteration" => (long_instructions - short_instructions) / (2 * iterations)
    }
  end

  @spec solve(String.t(), pos_integer()) :: :ok
  def solve(id, iterations) do
    model = id |> corpus_entry() |> Loader.load()

    {:ok, result} =
      ExVrp.solve(model, stop: StoppingCriteria.max_iterations(iterations), seed: 1, num_starts: 1)

    IO.puts("#{@solve_marker} distance=#{result.best.distance}")
  end

  @spec instructions_from_perf_csv(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def instructions_from_perf_csv(csv) do
    csv
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, ",instructions"))
    |> instruction_count()
  end

  @spec distance_from_solve_output(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def distance_from_solve_output(output) do
    case Regex.run(~r/#{@solve_marker} distance=(\d+)/, output) do
      [_line, distance] -> {:ok, String.to_integer(distance)}
      nil -> {:error, "the solve printed no #{@solve_marker} line:\n#{output}"}
    end
  end

  defp count_solve(id, iterations) do
    counter_file = Path.join(Mix.Project.build_path(), "bench_speed_#{id}_#{iterations}.csv")

    {output, status} =
      System.cmd("perf", perf_stat_args(counter_file, id, iterations),
        env: [{"ELIXIR_ERL_OPTIONS", @idle_schedulers_sleep}],
        stderr_to_stdout: true
      )

    {counted(counter_file, id, status, output), solved_distance(id, output)}
  end

  defp perf_stat_args(counter_file, id, iterations) do
    solve_call = "ExVrp.ABBenchmark.Speed.solve(#{inspect(id)}, #{iterations})"

    ["stat", "-x", ",", "-e", "instructions:u", "-o", counter_file, "--"] ++
      ["mix", "run", "--no-compile", "--no-deps-check", "-e", solve_call]
  end

  defp counted(counter_file, id, 0 = _status, _output) do
    with {:ok, csv} <- File.read(counter_file),
         {:ok, instructions} <- instructions_from_perf_csv(csv) do
      instructions
    else
      {:error, reason} -> raise SpeedMeasurementError, instance: id, reason: inspect(reason)
    end
  end

  defp counted(_counter_file, id, status, output),
    do: raise(SpeedMeasurementError, instance: id, reason: "perf stat exited #{status}:\n#{output}")

  defp solved_distance(id, output) do
    case distance_from_solve_output(output) do
      {:ok, distance} -> distance
      {:error, reason} -> raise SpeedMeasurementError, instance: id, reason: reason
    end
  end

  defp instruction_count(nil), do: {:error, "perf stat reported no instructions event"}

  defp instruction_count(line) do
    line |> String.split(",", parts: 2) |> hd() |> parse_count()
  end

  defp parse_count("<not supported>"),
    do: {:error, "this machine exposes no instruction counter (no PMU, or kernel.perf_event_paranoid > 2)"}

  defp parse_count("<not counted>"), do: {:error, "perf stat counted no instructions"}

  defp parse_count(count) do
    case Integer.parse(count) do
      {instructions, ""} -> {:ok, instructions}
      _ -> {:error, "unreadable instruction count #{inspect(count)}"}
    end
  end

  defp corpus_entry(id), do: Enum.find(Corpus.entries(), &(&1.id == id))
end

defmodule ExVrp.ABBenchmark.Speed do
  @moduledoc """
  Measures the solver's speed as instructions per search iteration, counted by Callgrind.

  Unlike iterations within a wall-clock budget, an instruction count does not depend
  on what else the machine runs, so two refs differ only by what their code does.
  Callgrind counts in software, so this needs no hardware counters and runs on
  GitHub-hosted runners; and since no count depends on load, instances measure
  concurrently.

  Every instance solves in a fresh BEAM, once for `n` iterations and once for `3n`.
  The difference over `2n` iterations drops instance loading and solver setup, which
  a single count would mix into the search's. Callgrind counts only inside NIF calls,
  which is the solver and the C and C++ library code it calls, and instruments nothing
  until the instance is loaded: booting a BEAM under instrumentation takes minutes.

  Valgrind cannot run the BEAM's JIT, so each solve runs on the interpreter-only Erlang
  that `interpreter_erlang.nix` builds from devenv's nixpkgs pin, with no super carrier
  (`+MMscs 0`), whose memory mapping Valgrind also cannot follow. Valgrind runs one
  thread at a time, and its default scheduling lets a thread spinning on a lock hold the
  CPU while the thread that owns the lock waits: on a busy runner, a BEAM solve under it
  once ran past thirty minutes against five on the run before. `--fair-sched=yes` hands
  the CPU over in order. It changes when each thread runs, not what the solver executes,
  so every count stays the same.

  The corpus is listed longest-running first. Instances measure as many at a time as
  there are schedulers, in list order, so the long ones start at once instead of
  queueing behind the short ones; on a four-core runner the job then takes as long as
  its longest instance. Order changes no count, only when each one is taken.

  A solve runs under a thirty-minute time limit, so one that runs away fails
  with its instance named instead of silently holding the job until the CI timeout; and
  every finished instance is logged, so a slow job shows how far it got.
  """

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Instance
  alias ExVrp.ABBenchmark.Loader
  alias ExVrp.ABBenchmark.SpeedMeasurementError
  alias ExVrp.StoppingCriteria

  require Logger

  @corpus [
    {"prod_clients_125", 150},
    {"prodbrk_clients_125", 50},
    {"cvrp_X-n439-k37", 400},
    {"c201", 600},
    {"pc_RC1_10_4", 200},
    {"mtr_R204R0.25", 400},
    {"pc_R1_10_4", 200}
  ]

  @interpreter_erlang_nix Path.expand("interpreter_erlang.nix", __DIR__)
  @nif_entry_points "*(enif_environment_t*, int, unsigned long const*)*"
  @valgrind_compatible_beam_flags ~w(+MMscs 0 +sbwt none +sbwtdcpu none +sbwtdio none)
  @solve_marker "BENCH_SPEED"
  @solve_time_limit_s 1_800
  @timed_out_status 124
  @killed_status 137

  @spec corpus() :: [{String.t(), pos_integer()}]
  def corpus, do: @corpus

  @spec run([{String.t(), pos_integer()}], String.t(), String.t()) :: map()
  def run(corpus, ref, commit) do
    interpreter_erl = build_interpreter_erl()

    %{
      "ref" => ref,
      "commit" => commit,
      "instances" =>
        corpus
        |> Task.async_stream(fn {id, iterations} -> {id, measure(interpreter_erl, id, iterations)} end,
          max_concurrency: System.schedulers_online(),
          timeout: :infinity,
          ordered: false
        )
        |> Map.new(fn {:ok, instance} -> instance end)
    }
  end

  @spec solve(String.t(), pos_integer()) :: :ok
  def solve(id, iterations) do
    %Instance{model: model, penalty_params: penalty_params} = id |> corpus_entry() |> Loader.load()
    start_instrumentation()

    {:ok, result} =
      ExVrp.solve(model,
        stop: StoppingCriteria.max_iterations(iterations),
        seed: 1,
        num_starts: 1,
        penalty_params: penalty_params
      )

    IO.puts("#{@solve_marker} distance=#{result.best.distance}")
  end

  @spec instructions_from_callgrind_out(String.t()) :: non_neg_integer()
  def instructions_from_callgrind_out(callgrind_out) do
    case Regex.run(~r/^totals: (\d+)/m, callgrind_out) do
      [_line, instructions] -> String.to_integer(instructions)
      nil -> 0
    end
  end

  @spec distance_from_solve_output(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def distance_from_solve_output(output) do
    case Regex.run(~r/#{@solve_marker} distance=(\d+)/, output) do
      [_line, distance] -> {:ok, String.to_integer(distance)}
      nil -> {:error, "the solve printed no #{@solve_marker} line:\n#{output}"}
    end
  end

  defp measure(interpreter_erl, id, iterations) do
    {short_instructions, short_distance} = count_solve(interpreter_erl, id, iterations)
    {long_instructions, long_distance} = count_solve(interpreter_erl, id, 3 * iterations)
    instructions_per_iteration = (long_instructions - short_instructions) / (2 * iterations)
    Logger.warning("[speed] #{id}: #{round(instructions_per_iteration)} instructions per iteration")

    %{
      "iterations" => [iterations, 3 * iterations],
      "distances" => [short_distance, long_distance],
      "instructions_per_iteration" => instructions_per_iteration
    }
  end

  defp build_interpreter_erl do
    "nix"
    |> System.cmd(["build", "--no-link", "--print-out-paths", "-f", @interpreter_erlang_nix], stderr_to_stdout: true)
    |> interpreter_erl_from_nix_build()
  end

  defp interpreter_erl_from_nix_build({out_path, 0}), do: Path.join(String.trim(out_path), "bin/erl")

  defp interpreter_erl_from_nix_build({output, status}),
    do: raise(SpeedMeasurementError, instance: "every instance", reason: "nix build exited #{status}:\n#{output}")

  defp start_instrumentation do
    {_output, 0} = System.cmd("callgrind_control", ["--instr=on", System.pid()], stderr_to_stdout: true)
  end

  defp count_solve(interpreter_erl, id, iterations) do
    out_dir = Path.join([Mix.Project.build_path(), "bench_speed", "#{id}_#{iterations}"])
    File.rm_rf!(out_dir)
    File.mkdir_p!(out_dir)

    {output, status} =
      System.cmd(
        "timeout",
        time_limit_args() ++ ["valgrind" | callgrind_args(out_dir)] ++ [interpreter_erl | solve_args(id, iterations)],
        env: [{"ERL_LIBS", erl_libs()}],
        stderr_to_stdout: true
      )

    {counted(out_dir, id, status, output), solved_distance(id, output)}
  end

  defp time_limit_args, do: ["--kill-after=30", "#{@solve_time_limit_s}"]

  defp callgrind_args(out_dir) do
    [
      "--tool=callgrind",
      "--fair-sched=yes",
      "--trace-children=yes",
      "--trace-children-skip=*/callgrind_control,*/perl,*/vgdb",
      "--instr-atstart=no",
      "--collect-atstart=no",
      "--toggle-collect=#{@nif_entry_points}",
      "--callgrind-out-file=#{out_dir}/callgrind.%p"
    ]
  end

  defp solve_args(id, iterations) do
    solve_call =
      "{ok, _} = application:ensure_all_started(ex_vrp), " <>
        "'Elixir.ExVrp.ABBenchmark.Speed':solve(<<#{inspect(id)}>>, #{iterations}), init:stop()."

    @valgrind_compatible_beam_flags ++ ["-noshell", "-eval", solve_call]
  end

  defp erl_libs do
    Enum.join([Path.join(Mix.Project.build_path(), "lib"), Path.dirname(:code.lib_dir(:elixir))], ":")
  end

  defp counted(out_dir, id, 0 = _status, _output) do
    out_dir
    |> Path.join("callgrind.*")
    |> Path.wildcard()
    |> Enum.sum_by(&(&1 |> File.read!() |> instructions_from_callgrind_out()))
    |> nonzero_count(id)
  end

  defp counted(_out_dir, id, @timed_out_status, output) do
    raise SpeedMeasurementError,
      instance: id,
      reason: "the solve did not finish within #{@solve_time_limit_s}s under Callgrind:\n#{output}"
  end

  defp counted(_out_dir, id, @killed_status, output) do
    raise SpeedMeasurementError,
      instance: id,
      reason:
        "the solve was killed: it ignored the stop at the #{@solve_time_limit_s}s time limit, " <>
          "or ran out of memory:\n#{output}"
  end

  defp counted(_out_dir, id, status, output),
    do: raise(SpeedMeasurementError, instance: id, reason: "valgrind exited #{status}:\n#{output}")

  defp nonzero_count(0, id),
    do: raise(SpeedMeasurementError, instance: id, reason: "Callgrind counted no instructions inside the solver")

  defp nonzero_count(instructions, _id), do: instructions

  defp solved_distance(id, output) do
    case distance_from_solve_output(output) do
      {:ok, distance} -> distance
      {:error, reason} -> raise SpeedMeasurementError, instance: id, reason: reason
    end
  end

  defp corpus_entry(id), do: Enum.find(Corpus.entries(), &(&1.id == id))
end

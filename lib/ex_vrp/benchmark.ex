defmodule ExVrp.Benchmark do
  @moduledoc """
  Benchmark suite for ex_vrp solver.

  Runs benchmarks on VRPLIB instances and compares solution quality
  against known best solutions.
  """

  alias ExVrp.Read
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @data_dir Path.join(:code.priv_dir(:ex_vrp), "benchmark_data")

  # Instance config: {filename, round_func, solution_file}
  # round_func values derived from PyVRP's conftest.py and test files
  @instances %{
    ok_small: {"OkSmall.txt", :none, "OkSmall.sol"},
    e_n22_k4: {"E-n22-k4.txt", :dimacs, nil},
    rc208: {"RC208.vrp", :dimacs, "RC208.sol"},
    pr11a: {"PR11A.vrp", :trunc, nil},
    c201: {"C201R0.25.vrp", :dimacs, "C201R0.25.sol"},
    small_vrpspd: {"SmallVRPSPD.vrp", :round, nil},
    p06: {"p06-2-50.vrp", :dimacs, nil},
    gtsp: {"50pr439.gtsp", :round, nil},
    pr107: {"pr107.tsp", :dimacs, nil}
    # Excluded due to overflow issues:
    # - pr01: floating-point coordinates
    # - x101: large instance causes overflow
    # - x115: exact rounding causes overflow
  }

  @doc """
  Returns list of all available benchmark instance names.
  """
  def available_instances, do: Map.keys(@instances)

  @doc """
  Runs benchmarks on the specified instances.

  ## Options

  - `:iterations` - Number of solver iterations per benchmark run (default: 100)
  - `:save` - Path to save JSON results (optional)

  ## Examples

      ExVrp.Benchmark.run(:all)
      ExVrp.Benchmark.run([:ok_small, :rc208], iterations: 50)

  """
  def run(instances, opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 100)
    save_path = Keyword.get(opts, :save)

    instance_list =
      if instances == :all do
        Map.keys(@instances)
      else
        instances
      end

    # First, run once to collect solution quality metrics
    IO.puts("\nCollecting solution quality metrics (seed=42, iterations=#{iterations})...\n")
    solution_metrics = collect_solution_metrics(instance_list, iterations)

    # Print solution quality report
    print_solution_report(solution_metrics, instance_list)

    # Build benchmark scenarios for timing
    scenarios = build_scenarios(instance_list, iterations)

    # Run with Benchee for timing
    IO.puts("\nRunning timing benchmarks...\n")

    results =
      Benchee.run(scenarios,
        warmup: 1,
        time: 5,
        memory_time: 0,
        formatters: [Benchee.Formatters.Console]
      )

    if save_path, do: save_results(results, solution_metrics, save_path)
    results
  end

  defp collect_solution_metrics(instances, iterations) do
    for name <- instances,
        Map.has_key?(@instances, name),
        into: %{} do
      {file, round_func, sol_file} = @instances[name]
      path = Path.join(@data_dir, file)

      IO.write("  #{name}...")

      model = Read.read(path, round_func: round_func)
      stop = StoppingCriteria.max_iterations(iterations)
      {:ok, result} = Solver.solve(model, stop: stop, seed: 42)

      bks =
        if sol_file do
          raw_cost = parse_solution_cost(Path.join(@data_dir, sol_file))
          scale_bks(raw_cost, round_func)
        else
          nil
        end

      IO.puts(" done (distance: #{result.best.distance})")

      {name,
       %{
         distance: result.best.distance,
         feasible: result.best.is_feasible,
         iterations: result.num_iterations,
         routes: length(result.best.routes),
         runtime_ms: result.runtime,
         bks: bks
       }}
    end
  end

  defp print_solution_report(metrics, instances) do
    IO.puts("")
    IO.puts("╔══════════════════════════════════════════════════════════════════════╗")
    IO.puts("║                      Solution Quality Report                         ║")
    IO.puts("╠══════════════╦══════════════╦══════════╦════════════╦════════════════╣")
    IO.puts("║ Instance     ║ Distance     ║ Feasible ║ Routes     ║ vs BKS         ║")
    IO.puts("╠══════════════╬══════════════╬══════════╬════════════╬════════════════╣")

    for name <- instances, Map.has_key?(metrics, name) do
      m = metrics[name]
      bks_comparison = format_bks_comparison(m.distance, m.bks)

      IO.puts(
        "║ #{pad(to_string(name), 12)} ║ #{pad_num(m.distance, 12)} ║ #{pad(to_string(m.feasible), 8)} ║ #{pad_num(m.routes, 10)} ║ #{pad(bks_comparison, 14)} ║"
      )
    end

    IO.puts("╚══════════════╩══════════════╩══════════╩════════════╩════════════════╝")
    IO.puts("")
  end

  defp format_bks_comparison(_distance, nil), do: "N/A"

  defp format_bks_comparison(distance, bks) when is_number(distance) and is_number(bks) do
    gap = (distance - bks) / bks * 100

    cond do
      abs(gap) < 0.01 -> "0.0% (optimal)"
      gap > 0 -> "+#{Float.round(gap, 1)}%"
      true -> "#{Float.round(gap, 1)}%"
    end
  end

  defp format_bks_comparison(_, _), do: "N/A"

  defp pad(str, width), do: String.pad_trailing(str, width)

  defp pad_num(num, width) when is_integer(num) do
    num |> Integer.to_string() |> String.pad_leading(width)
  end

  defp pad_num(num, width) when is_float(num) do
    num |> Float.round(2) |> Float.to_string() |> String.pad_leading(width)
  end

  defp pad_num(num, width), do: to_string(num) |> String.pad_leading(width)

  defp build_scenarios(instances, iterations) do
    for name <- instances, Map.has_key?(@instances, name), into: %{} do
      {file, round_func, _sol_file} = @instances[name]
      path = Path.join(@data_dir, file)

      scenario_fn = fn ->
        model = Read.read(path, round_func: round_func)
        stop = StoppingCriteria.max_iterations(iterations)
        {:ok, _result} = Solver.solve(model, stop: stop, seed: 42)
      end

      {to_string(name), scenario_fn}
    end
  end

  defp parse_solution_cost(sol_path) do
    case File.read(sol_path) do
      {:ok, content} ->
        case Regex.run(~r/Cost\s+(\d+(?:\.\d+)?)/i, content) do
          [_, cost_str] ->
            case Float.parse(cost_str) do
              {val, _} -> val
              :error -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  # Scale BKS value to match the rounding function applied to instance data
  defp scale_bks(nil, _round_func), do: nil

  defp scale_bks(cost, :dimacs), do: trunc(cost * 10)
  defp scale_bks(cost, :exact), do: round(cost * 1000)
  defp scale_bks(cost, :round), do: round(cost)
  defp scale_bks(cost, :trunc), do: trunc(cost)
  defp scale_bks(cost, :none), do: cost
  defp scale_bks(cost, _), do: cost

  defp save_results(benchee_results, solution_metrics, path) do
    data =
      for scenario <- benchee_results.scenarios, into: %{} do
        name = scenario.name
        stats = scenario.run_time_data.statistics
        sol_metrics = Map.get(solution_metrics, String.to_atom(name), %{})

        {name,
         %{
           timing: %{
             mean_ms: stats.average / 1_000_000,
             median_ms: stats.median / 1_000_000,
             std_dev_ratio: stats.std_dev_ratio,
             ips: stats.ips
           },
           solution: sol_metrics
         }}
      end

    json = Jason.encode!(data, pretty: true)
    File.write!(path, json)
    IO.puts("\nResults saved to #{path}")
  end
end

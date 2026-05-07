defmodule ExVrp.Benchmark do
  @moduledoc """
  Benchmark suite for ex_vrp solver.

  Runs benchmarks on VRPLIB instances with multiple seeds and reports
  solution quality regressions against known expected distances (seed=42).
  """

  alias ExVrp.Read
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  require Logger

  @data_dir Path.join(:code.priv_dir(:ex_vrp), "benchmark_data")
  @seeds [42, 1, 1337]

  @instances %{
    small_vrpspd: {"SmallVRPSPD.vrp", :round},
    ok_small: {"OkSmall.txt", :none},
    e_n22_k4: {"E-n22-k4.txt", :dimacs},
    p06: {"p06-2-50.vrp", :dimacs},
    pr01: {"PR01.vrp", :none},
    pr107: {"pr107.tsp", :dimacs},
    rc208: {"RC208.vrp", :dimacs},
    x101: {"X-n101-50-k13.vrp", :round},
    gtsp: {"50pr439.gtsp", :round},
    c201: {"C201R0.25.vrp", :dimacs},
    x115: {"X115-HVRP.vrp", :exact},
    pr11a: {"PR11A.vrp", :trunc}
  }

  @expected_distances %{
    small_vrpspd: 82,
    ok_small: 9155,
    e_n22_k4: 3743,
    p06: 829,
    pr01: 1627,
    pr107: 443_004,
    rc208: 7870,
    x101: 19_467,
    gtsp: 45_235,
    c201: 10_773,
    x115: 17_368_625,
    pr11a: 6881
  }

  def expected_distances, do: @expected_distances
  def available_instances, do: Map.keys(@instances)

  @doc """
  Runs benchmarks on the specified instances.

  ## Options

  - `:iterations` - Number of solver iterations per run (default: 1000)
  - `:save` - Path to save JSON results

  ## Examples

      ExVrp.Benchmark.run(:all)
      ExVrp.Benchmark.run([:ok_small, :rc208], iterations: 500)

  """
  def run(instances, opts \\ []) do
    iterations = Keyword.get(opts, :iterations, 1000)
    save_path = Keyword.get(opts, :save)

    instance_list =
      if instances == :all, do: @instances |> Map.keys() |> Enum.sort(), else: instances

    IO.puts("\nRunning benchmarks (seeds=#{inspect(@seeds)}, iterations=#{iterations})...\n")

    prev_level = Logger.level()
    Logger.configure(level: :warning)
    results = collect_results(instance_list, iterations)
    Logger.configure(level: prev_level)

    print_report(results, iterations)

    if save_path, do: save_json(results, save_path)
    results
  end

  defp collect_results(instances, iterations) do
    for name <- instances, Map.has_key?(@instances, name) do
      {file, round_func} = @instances[name]
      path = Path.join(@data_dir, file)
      model = Read.read(path, round_func: round_func)

      IO.write("  #{name}...")

      seed_results =
        for seed <- @seeds do
          stop = StoppingCriteria.max_iterations(iterations)
          {:ok, result} = Solver.solve(model, stop: stop, seed: seed, num_starts: 1)
          {seed, result.best.distance, result.best.is_feasible}
        end

      best = seed_results |> Enum.map(&elem(&1, 1)) |> Enum.min()
      all_feasible = Enum.all?(seed_results, &elem(&1, 2))

      IO.puts(" best=#{best} (all_feasible=#{all_feasible})")

      {name, %{seed_results: seed_results, best: best, all_feasible: all_feasible}}
    end
  end

  defp print_report(results, iterations) do
    IO.puts("")
    IO.puts("Regression Report (seeds=#{inspect(@seeds)}, iterations=#{iterations})")
    IO.puts(String.duplicate("-", 72))

    IO.puts(
      "#{rpad("Instance", 14)} #{lpad("Seed 42", 10)} #{lpad("Expected", 10)} #{rpad("Quality", 11)} #{lpad("Best", 10)} #{rpad("Feasible", 8)}"
    )

    IO.puts(String.duplicate("-", 72))

    {pass, fail} =
      Enum.reduce(results, {0, 0}, fn {name, m}, {p, f} ->
        expected = @expected_distances[name]

        seed_42_dist =
          Enum.find_value(m.seed_results, fn
            {42, dist, _} -> dist
            _ -> nil
          end)

        quality =
          cond do
            seed_42_dist == expected and m.all_feasible -> "ok"
            seed_42_dist != expected -> "REGRESSED"
            not m.all_feasible -> "INFEASIBLE"
          end

        feasible_count = Enum.count(m.seed_results, &elem(&1, 2))
        feasible_str = "#{feasible_count}/#{length(@seeds)}"

        IO.puts(
          "#{rpad(to_string(name), 14)} #{lpad(to_string(seed_42_dist), 10)} #{lpad(to_string(expected), 10)} #{rpad(quality, 11)} #{lpad(to_string(m.best), 10)} #{rpad(feasible_str, 8)}"
        )

        if quality == "ok", do: {p + 1, f}, else: {p, f + 1}
      end)

    IO.puts(String.duplicate("-", 72))

    IO.puts("Quality: #{pass}/#{pass + fail} passed")
    IO.puts("")

    if fail > 0 do
      IO.puts("BENCHMARK REGRESSION DETECTED")
    else
      IO.puts("All benchmarks passed.")
    end

    IO.puts("")
  end

  defp rpad(str, width), do: String.pad_trailing(str, width)
  defp lpad(str, width), do: String.pad_leading(str, width)

  defp save_json(results, path) do
    data =
      for {name, m} <- results, into: %{} do
        seeds =
          for {seed, dist, feasible} <- m.seed_results, into: %{} do
            {to_string(seed), %{distance: dist, feasible: feasible}}
          end

        {to_string(name), %{best: m.best, all_feasible: m.all_feasible, seeds: seeds}}
      end

    File.write!(path, Jason.encode!(data, pretty: true))
    IO.puts("Results saved to #{path}")
  end
end

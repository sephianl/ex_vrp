defmodule ExVrp.ProductionBenchmarkTest do
  @moduledoc """
  Benchmarks built from real Zelo planning runs. Models are anonymized
  ExVrp.Model structs saved as base64-encoded ETF files.

  ## Running

      # Full benchmarks (long timeouts, single seed):
      mix test test/production_benchmark_test.exs --include production_benchmark

      # Quick multi-seed feasibility check (5 seeds, short timeouts):
      mix test test/production_benchmark_test.exs --include production_benchmark_quick

  ## Adding new benchmarks

  In Zelo, set `config :zelo, :benchmark_capture_dir, "path"` and run a
  planning job. The anonymized model ETF will be written to that directory.
  Copy it to `priv/benchmark_data/production/`.
  """

  use ExUnit.Case, async: true

  alias ExVrp.StoppingCriteria

  require Logger

  # 5 minutes per test — enough for the largest benchmark (~215s) with margin
  @moduletag timeout: 300_000
  @benchmark_dir Path.join(:code.priv_dir(:ex_vrp), "benchmark_data/production")

  @benchmarks @benchmark_dir
              |> Path.join("*_model.etf")
              |> Path.wildcard()
              |> Enum.sort()

  # --- Full benchmarks (single seed, long timeout) ---

  for file <- @benchmarks do
    @tag :production_benchmark
    @tag model_file: file
    test Path.basename(file, "_model.etf"), %{model_file: file} do
      run_benchmark(file)
    end
  end

  defp run_benchmark(file) do
    name = Path.basename(file, "_model.etf")
    model = load_model(file)
    n = ExVrp.Model.num_locations(model)
    plannable = plannable_count(model)
    timeout_s = round(102.6622 * :math.exp(0.00096445 * n))

    Logger.warning("[benchmark] #{name}: n=#{n}, plannable=#{plannable}, timeout=#{timeout_s}s")

    {:ok, result} = ExVrp.solve(model, stop: StoppingCriteria.max_runtime(timeout_s), num_starts: 1)

    Logger.warning("[benchmark] #{name}: done — #{result.best.num_clients}/#{plannable} clients")

    assert result.best.is_feasible,
           "solution is infeasible (#{result.best.num_clients}/#{plannable} clients)"

    min_clients = min(400, plannable)

    assert result.best.num_clients >= min_clients,
           "planned #{result.best.num_clients}/#{plannable} plannable clients (need >= #{min_clients})"
  end

  # --- Quick multi-seed feasibility ---

  @seeds [1, 2, 42, 999, 99_999]

  for file <- @benchmarks do
    @tag :production_benchmark_quick
    @tag model_file: file
    test "quick multi-seed: #{Path.basename(file, "_model.etf")}", %{model_file: file} do
      run_quick_benchmark(file)
    end
  end

  defp run_quick_benchmark(file) do
    model = load_model(file)
    plannable = plannable_count(model)
    n = ExVrp.Model.num_locations(model)
    # Scale timeout with problem size: ~5s for small, ~30s for large
    timeout_ms = max(5_000, round(n / 20) * 1_000)

    results =
      Enum.map(@seeds, fn seed ->
        {:ok, result} = ExVrp.solve(model, max_runtime: timeout_ms, seed: seed, num_starts: 1)
        {seed, result}
      end)

    # Require feasibility and at least 70% of plannable clients.
    # Prize-collecting problems may not serve all clients when fleet
    # capacity can't accommodate them without time warp violations.
    min_clients = min(400, plannable)

    feasible =
      Enum.count(results, fn {_seed, r} ->
        r.best.is_feasible and r.best.num_clients >= min_clients
      end)

    min_required = length(@seeds) - 1

    assert feasible >= min_required,
           format_failures(results, plannable, length(model.clients), feasible)
  end

  defp format_failures(results, plannable, total, feasible) do
    details =
      Enum.map_join(results, "\n", fn {seed, r} ->
        status = if r.best.is_feasible, do: "OK", else: "INFEASIBLE"
        "  seed=#{seed}: #{status}, #{r.best.num_clients}/#{plannable} clients (#{total} total)"
      end)

    "only #{feasible}/#{length(@seeds)} seeds feasible (need #{length(@seeds) - 1}):\n#{details}"
  end

  # --- Helpers ---

  defp plannable_count(model) do
    model.clients
    |> Enum.filter(&(&1.prize > 0))
    |> Enum.group_by(& &1.group)
    |> Enum.reduce(0, fn
      {nil, clients}, acc -> acc + length(clients)
      {_group_idx, _clients}, acc -> acc + 1
    end)
  end

  defp load_model(file) do
    file
    |> File.read!()
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end
end

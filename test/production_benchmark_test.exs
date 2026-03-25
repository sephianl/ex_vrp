defmodule ExVrp.ProductionBenchmarkTest do
  @moduledoc """
  Benchmarks built from real Zelo planning runs. Models are anonymized
  ExVrp.Model structs saved as base64-encoded ETF files.

  ## Running

      mix test test/production_benchmark_test.exs --include production_benchmark

  ## Adding new benchmarks

  In Zelo, set `config :zelo, :benchmark_capture_dir, "path"` and run a
  planning job. The anonymized model ETF will be written to that directory.
  Copy it to `priv/benchmark_data/production/`.
  """

  use ExUnit.Case, async: false

  alias ExVrp.StoppingCriteria

  @moduletag :production_benchmark
  @moduletag timeout: :infinity
  @benchmark_dir Path.join(:code.priv_dir(:ex_vrp), "benchmark_data/production")

  @benchmarks @benchmark_dir
              |> Path.join("*_model.etf")
              |> Path.wildcard()
              |> Enum.sort()

  for file <- @benchmarks do
    @tag model_file: file
    test Path.basename(file, "_model.etf"), %{model_file: file} do
      run_benchmark(file)
    end
  end

  defp run_benchmark(file) do
    model = load_model(file)
    n = ExVrp.Model.num_locations(model)
    timeout_s = round(102.6622 * :math.exp(0.00096445 * n))

    {:ok, result} = ExVrp.solve(model, stop: StoppingCriteria.max_runtime(timeout_s))

    plannable = plannable_count(model)

    assert result.best.num_clients == plannable,
           "planned #{result.best.num_clients}/#{plannable} plannable clients (#{length(model.clients)} total)"
  end

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

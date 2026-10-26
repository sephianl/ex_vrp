defmodule ExVrp.Literature.Manifest do
  @moduledoc """
  The fetched literature instances, as `mix bench.lit.fetch` writes them to
  `priv/benchmark_data/literature/manifest.json` (gitignored, since fetching reproduces it).
  Instance paths are relative to that directory, so a fetched tree can be copied to the
  machine that runs the benchmark.
  """

  alias ExVrp.Literature.BenchmarkInstance

  @spec data_dir() :: String.t()
  def data_dir, do: Path.join([File.cwd!(), "priv", "benchmark_data", "literature"])

  @spec write([BenchmarkInstance.t()], map()) :: :ok
  def write(instances, provenance) do
    json = %{"provenance" => provenance, "instances" => Enum.map(instances, &BenchmarkInstance.to_json/1)}
    File.write!(manifest_path(), Jason.encode_to_iodata!(json, pretty: true))
  end

  @spec read() :: {:ok, [BenchmarkInstance.t()]} | {:error, String.t()}
  def read do
    with {:ok, body} <- File.read(manifest_path()),
         {:ok, %{"instances" => instances}} <- Jason.decode(body) do
      {:ok, Enum.map(instances, &BenchmarkInstance.from_json/1)}
    else
      _missing_or_invalid -> {:error, "no literature manifest at #{manifest_path()}; run `mix bench.lit.fetch` first"}
    end
  end

  @spec absolute_path(BenchmarkInstance.t()) :: String.t()
  def absolute_path(%BenchmarkInstance{path: path}), do: Path.join(data_dir(), path)

  defp manifest_path, do: Path.join(data_dir(), "manifest.json")
end

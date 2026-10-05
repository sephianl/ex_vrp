defmodule ExVrp.ABBenchmark.Corpus do
  @moduledoc """
  Declares the A/B benchmark corpus: each instance's id, variant, how to load
  it, and its file path. BKS values are resolved separately via `bks/1`.

  Every production instance also runs as a `:production_breaks` twin, which
  `ExVrp.ABBenchmark.Loader` gives every vehicle type limits between breaks, so
  a change is measured on plans that need breaks as well as on plans without.
  The CI A/B builds the base solver under this harness; a base from before
  breaks has no break fields, so it declares no twins, and the comparison
  leaves them out instead of scoring them infeasible.
  """

  defmodule Entry do
    @moduledoc false
    @type t :: %__MODULE__{
            id: String.t(),
            variant: atom(),
            kind: :vrplib | :etf,
            path: String.t(),
            round_func: atom()
          }
    @enforce_keys [:id, :variant, :kind, :path]
    defstruct [:id, :variant, :kind, :path, round_func: :round]
  end

  @data_dir Path.join(:code.priv_dir(:ex_vrp), "benchmark_data")
  @curated_dir Path.join(@data_dir, "curated")
  @bks_path Path.join(@data_dir, "bks.json")

  @literature [
    {"ok_small", "OkSmall.txt", :vrptw, :none},
    {"e_n22_k4", "E-n22-k4.txt", :cvrp, :dimacs},
    {"rc208", "RC208.vrp", :vrptw, :dimacs},
    {"x101", "X-n101-50-k13.vrp", :cvrp, :round},
    {"c201", "C201R0.25.vrp", :vrptw, :dimacs},
    {"pr01", "PR01.vrp", :cvrp, :none},
    {"x115", "X115-HVRP.vrp", :cvrp, :exact}
  ]

  @curated [
    {"cvrp_X-n439-k37", "X-n439-k37.vrp", :cvrp, :round},
    {"cvrp_X-n749-k98", "X-n749-k98.vrp", :cvrp, :round},
    {"vrptw_R101", "R101.vrp", :vrptw, :dimacs},
    {"pc_R1_10_4", "R1_10_4.vrp", :pcvrptw, :dimacs},
    {"pc_RC1_10_4", "RC1_10_4.vrp", :pcvrptw, :dimacs},
    {"mtr_R204R0.25", "R204R0.25.vrp", :mtvrptwr, :dimacs},
    {"mtr_C201R0.5", "C201R0.5.vrp", :mtvrptwr, :dimacs}
  ]

  @spec entries() :: [Entry.t()]
  def entries do
    literature_entries() ++ curated_entries() ++ production_entries() ++ production_break_entries(breaks_supported?())
  end

  @spec bks(String.t()) :: number() | nil
  def bks(id), do: Map.get(bks_map(), id)

  defp bks_map do
    case File.read(@bks_path) do
      {:ok, body} -> Jason.decode!(body)
      {:error, _} -> %{}
    end
  end

  defp literature_entries do
    for {id, file, variant, rf} <- @literature do
      %Entry{id: id, variant: variant, kind: :vrplib, path: Path.join(@data_dir, file), round_func: rf}
    end
  end

  defp curated_entries do
    for {id, file, variant, rf} <- @curated do
      %Entry{id: id, variant: variant, kind: :vrplib, path: Path.join(@curated_dir, file), round_func: rf}
    end
  end

  defp production_entries do
    @data_dir
    |> Path.join("production/*_model.etf")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      id = "prod_" <> Path.basename(path, "_model.etf")
      %Entry{id: id, variant: :production, kind: :etf, path: path}
    end)
  end

  defp production_break_entries(false = _breaks_supported), do: []

  defp production_break_entries(true = _breaks_supported) do
    Enum.map(production_entries(), fn %Entry{id: "prod_" <> name} = entry ->
      %{entry | id: "prodbrk_" <> name, variant: :production_breaks}
    end)
  end

  defp breaks_supported?, do: ExVrp.VehicleType |> struct() |> Map.has_key?(:break_duration)
end

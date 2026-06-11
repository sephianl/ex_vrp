defmodule ExVrp.ABBenchmark.Loader do
  @moduledoc """
  Loads a corpus entry into an `ExVrp.Model`. VRPLIB entries go through
  `ExVrp.Read`; ETF entries are base64-decoded, deserialized, and migrated so
  fields added after capture get default values.

  ETF deserialization runs without `[:safe]` on purpose: these are trusted,
  repo-local production model snapshots that legitimately carry atoms not yet
  loaded in a fresh VM, which `[:safe]` would reject.
  """

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.Read

  @spec load(Corpus.Entry.t()) :: ExVrp.Model.t()
  def load(%Corpus.Entry{kind: :vrplib, path: path, round_func: rf}) do
    Read.read(path, round_func: rf)
  end

  def load(%Corpus.Entry{kind: :etf, path: path}) do
    path
    |> File.read!()
    |> Base.decode64!()
    |> :erlang.binary_to_term()
    |> migrate_model()
  end

  defp migrate_model(%{__struct__: ExVrp.Model} = model) do
    model
    |> restruct()
    |> Map.update!(:vehicle_types, fn vts -> Enum.map(vts, &restruct/1) end)
    |> Map.update!(:clients, fn cs -> Enum.map(cs, &restruct/1) end)
    |> Map.update!(:depots, fn ds -> Enum.map(ds, &restruct/1) end)
    |> Map.update!(:client_groups, fn cgs -> Enum.map(cgs, &restruct/1) end)
    |> Map.update!(:same_vehicle_groups, fn svgs -> Enum.map(svgs, &restruct/1) end)
  end

  defp restruct(%{__struct__: module} = s), do: struct(module, Map.from_struct(s))
end

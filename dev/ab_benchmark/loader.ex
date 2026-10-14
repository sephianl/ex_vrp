defmodule ExVrp.ABBenchmark.Loader do
  @moduledoc """
  Loads a corpus entry into an `ExVrp.ABBenchmark.Instance`: the model, and the
  penalty bounds it has to be solved under. VRPLIB entries go through `ExVrp.Read`;
  ETF entries are base64-decoded, deserialized, and migrated so fields added after
  capture get default values.

  A production capture is either a bare `ExVrp.Model` or a map holding the model and
  the `ExVrp.PenaltyManager.Params` Zelo solved it with. The bounds belong to the
  capture because they follow its cost scale: Zelo models are priced in micro-euros,
  where the default ceiling of 100 000 per unit of time warp makes a vehicle's fixed
  cost worth hours of lateness, so solving such a model under the defaults measures
  a regime production never runs in. A bare model is solved under the defaults.

  ETF deserialization runs without `[:safe]` on purpose: these are trusted,
  repo-local production model snapshots that legitimately carry atoms not yet
  loaded in a fresh VM, which `[:safe]` would reject.

  A `:production_breaks` entry is its production snapshot with the same limits
  between breaks on every vehicle type. The snapshots' durations are seconds.
  """

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Instance
  alias ExVrp.PenaltyManager
  alias ExVrp.Read

  @break_limits [break_duration: 1_800, max_drive_between_breaks: 14_400, max_work_between_breaks: 18_000]

  @spec load(Corpus.Entry.t()) :: Instance.t()
  def load(%Corpus.Entry{kind: :vrplib, path: path, round_func: rf}) do
    %Instance{model: Read.read(path, round_func: rf)}
  end

  def load(%Corpus.Entry{kind: :etf, variant: :production_breaks, path: path}) do
    path
    |> load_etf()
    |> Map.update!(:model, &with_break_limits/1)
  end

  def load(%Corpus.Entry{kind: :etf, path: path}), do: load_etf(path)

  defp with_break_limits(model) do
    Map.update!(model, :vehicle_types, fn vehicle_types -> Enum.map(vehicle_types, &struct!(&1, @break_limits)) end)
  end

  defp load_etf(path) do
    path
    |> File.read!()
    |> Base.decode64!()
    |> :erlang.binary_to_term()
    |> to_instance()
  end

  defp to_instance(%{model: model, penalty_params: %{__struct__: PenaltyManager.Params} = penalty_params}) do
    %Instance{model: migrate_model(model), penalty_params: restruct(penalty_params)}
  end

  defp to_instance(%{__struct__: ExVrp.Model} = model), do: %Instance{model: migrate_model(model)}

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

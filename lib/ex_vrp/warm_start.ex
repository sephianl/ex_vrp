defmodule ExVrp.WarmStart do
  @moduledoc false

  alias ExVrp.Native

  @type solution_trip :: %{start_depot: non_neg_integer(), clients: [non_neg_integer()]}

  @doc """
  Each route of a solution as `{vehicle_type, trips}`, trips in `Native.solution_trips/1`'s shape.
  """
  @spec vehicle_type_trips(reference()) :: [{non_neg_integer(), [solution_trip()]}]
  def vehicle_type_trips(solution_ref) do
    solution_ref
    |> Native.solution_trips()
    |> Enum.with_index(fn trips, idx -> {Native.solution_route_vehicle_type(solution_ref, idx), trips} end)
  end

  @doc """
  One route's trips as an `:initial_routes` entry: a flat client list for a single trip, else
  `{:trips, [...]}` with the first trip leaving from the start depot (`reload_depot: nil`) and each
  later one from the depot it reloaded at.
  """
  @spec from_trips([solution_trip(), ...]) :: Native.warm_start_visits()
  def from_trips([%{clients: clients}]), do: clients

  def from_trips([first | reloads]) do
    {:trips,
     [
       %{reload_depot: nil, clients: first.clients}
       | Enum.map(reloads, &%{reload_depot: &1.start_depot, clients: &1.clients})
     ]}
  end
end

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
  The routes with each of the given break clients turned into a `:break` marker, since their
  indices would not survive a model that changed. A trip with no other client goes, as does a
  route left without trips.
  """
  @spec with_break_markers([{non_neg_integer(), [solution_trip()]}], MapSet.t(non_neg_integer())) ::
          [{non_neg_integer(), [solution_trip()]}]
  def with_break_markers(vehicle_type_trips, breaks) do
    vehicle_type_trips
    |> Enum.map(fn {vehicle_type, trips} -> {vehicle_type, trips_with_markers(trips, breaks)} end)
    |> Enum.reject(fn {_vehicle_type, trips} -> trips == [] end)
  end

  defp trips_with_markers(trips, breaks) do
    trips
    |> Enum.map(fn trip -> %{trip | clients: Enum.map(trip.clients, &marker(&1, breaks))} end)
    |> Enum.reject(fn trip -> Enum.all?(trip.clients, &(&1 == :break)) end)
  end

  defp marker(client, breaks), do: if(MapSet.member?(breaks, client), do: :break, else: client)

  @doc """
  The `:initial_routes` entries with each `:break` marker replaced by a break client of its own
  from `pool`, or an error when the markers outnumber it. Anything malformed passes through for
  the NIF to reject.
  """
  @spec place_breaks([{non_neg_integer(), Native.warm_start_visits()}], [non_neg_integer()]) ::
          {:ok, [{non_neg_integer(), Native.warm_start_visits()}]} | {:error, String.t()}
  def place_breaks(routes, pool) do
    routes
    |> Enum.sum_by(fn {_vehicle_type, visits} -> count_markers(visits) end)
    |> place_within(length(pool), routes, pool)
  end

  defp place_within(markers, pool_size, _routes, _pool) when markers > pool_size,
    do: {:error, "#{markers} :break markers, but the model's pool holds #{pool_size} breaks"}

  defp place_within(_markers, _pool_size, routes, pool) do
    {placed, _unused} = Enum.map_reduce(routes, pool, &place_route/2)
    {:ok, placed}
  end

  defp count_markers({:trips, trips}) when is_list(trips), do: Enum.sum_by(trips, &count_trip_markers/1)
  defp count_markers(clients) when is_list(clients), do: Enum.count(clients, &(&1 == :break))
  defp count_markers(_malformed), do: 0

  defp count_trip_markers(%{clients: clients}), do: count_markers(clients)
  defp count_trip_markers(_malformed), do: 0

  defp place_route({vehicle_type, visits}, pool) do
    {placed, rest} = place_visits(visits, pool)
    {{vehicle_type, placed}, rest}
  end

  defp place_visits({:trips, trips}, pool) when is_list(trips) do
    {placed, rest} = Enum.map_reduce(trips, pool, &place_trip/2)
    {{:trips, placed}, rest}
  end

  defp place_visits(clients, pool) when is_list(clients), do: Enum.map_reduce(clients, pool, &place_client/2)
  defp place_visits(malformed, pool), do: {malformed, pool}

  defp place_trip(%{clients: clients} = trip, pool) when is_list(clients) do
    {placed, rest} = place_visits(clients, pool)
    {%{trip | clients: placed}, rest}
  end

  defp place_trip(malformed, pool), do: {malformed, pool}

  defp place_client(:break, [client | rest]), do: {client, rest}
  defp place_client(client, pool), do: {client, pool}

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

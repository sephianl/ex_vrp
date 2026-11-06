defmodule ExVrp.WarmStart do
  @moduledoc false

  alias ExVrp.Native
  alias ExVrp.Solution

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
  The model's pause clients by marker: its break clients under `:break`, its rest clients under
  `:rest`, each in order.
  """
  @spec pause_pools(reference()) :: %{break: [non_neg_integer()], rest: [non_neg_integer()]}
  def pause_pools(problem_data),
    do: %{break: Native.problem_data_break_clients(problem_data), rest: Native.problem_data_rest_clients(problem_data)}

  @doc """
  The routes with each pause client of `problem_data` turned into its marker, `:break` or `:rest`,
  since the pool's indices follow the model's own clients and would not survive a model that
  changed. A trip with no other client goes, as does a route left without trips.
  """
  @spec with_pause_markers([{non_neg_integer(), [solution_trip()]}], reference()) ::
          [{non_neg_integer(), [solution_trip()]}]
  def with_pause_markers(vehicle_type_trips, problem_data) do
    markers =
      for {marker, clients} <- pause_pools(problem_data), client <- clients, into: %{}, do: {client, marker}

    vehicle_type_trips
    |> Enum.map(fn {vehicle_type, trips} -> {vehicle_type, trips_with_markers(trips, markers)} end)
    |> Enum.reject(fn {_vehicle_type, trips} -> trips == [] end)
  end

  defp trips_with_markers(trips, markers) do
    trips
    |> Enum.map(fn trip -> %{trip | clients: Enum.map(trip.clients, &Map.get(markers, &1, &1))} end)
    |> Enum.reject(fn trip -> Enum.all?(trip.clients, &pause_marker?/1) end)
  end

  defp pause_marker?(visit), do: visit in [:break, :rest]

  @doc """
  The `:initial_routes` entries with each `:break` and `:rest` marker replaced by a client of its
  own from that marker's pool in `pause_pools/1`, or an error when a marker outnumbers its pool.
  Anything malformed passes through for the NIF to reject.
  """
  @spec place_pauses([{non_neg_integer(), Solution.warm_start_visits()}], %{
          break: [non_neg_integer()],
          rest: [non_neg_integer()]
        }) ::
          {:ok, [{non_neg_integer(), Solution.warm_start_visits()}]} | {:error, String.t()}
  def place_pauses(routes, pools) do
    routes
    |> Enum.flat_map(fn {_vehicle_type, visits} -> markers(visits) end)
    |> Enum.frequencies()
    |> Enum.find(fn {marker, count} -> count > length(Map.fetch!(pools, marker)) end)
    |> place_within(routes, pools)
  end

  defp place_within({marker, count}, _routes, pools),
    do: {:error, "#{count} #{inspect(marker)} markers, but the model's pool holds #{length(pools[marker])}"}

  defp place_within(nil, routes, pools) do
    {placed, _unused} = Enum.map_reduce(routes, pools, &place_route/2)
    {:ok, placed}
  end

  defp markers({:trips, trips}) when is_list(trips), do: Enum.flat_map(trips, &trip_markers/1)
  defp markers(clients) when is_list(clients), do: Enum.filter(clients, &pause_marker?/1)
  defp markers(_malformed), do: []

  defp trip_markers(%{clients: clients}), do: markers(clients)
  defp trip_markers(_malformed), do: []

  defp place_route({vehicle_type, visits}, pools) do
    {placed, rest} = place_visits(visits, pools)
    {{vehicle_type, placed}, rest}
  end

  defp place_visits({:trips, trips}, pools) when is_list(trips) do
    {placed, rest} = Enum.map_reduce(trips, pools, &place_trip/2)
    {{:trips, placed}, rest}
  end

  defp place_visits(clients, pools) when is_list(clients), do: Enum.map_reduce(clients, pools, &place_client/2)
  defp place_visits(malformed, pools), do: {malformed, pools}

  defp place_trip(%{clients: clients} = trip, pools) when is_list(clients) do
    {placed, rest} = place_visits(clients, pools)
    {%{trip | clients: placed}, rest}
  end

  defp place_trip(malformed, pools), do: {malformed, pools}

  defp place_client(marker, pools) when marker in [:break, :rest] do
    [client | rest] = Map.fetch!(pools, marker)
    {client, %{pools | marker => rest}}
  end

  defp place_client(client, pools), do: {client, pools}

  @doc """
  One route's trips as an `:initial_routes` entry: a flat client list for a single trip, else
  `{:trips, [...]}` with the first trip leaving from the start depot (`reload_depot: nil`) and each
  later one from the depot it reloaded at.
  """
  @spec from_trips([solution_trip(), ...]) :: Solution.warm_start_visits()
  def from_trips([%{clients: clients}]), do: clients

  def from_trips([first | reloads]) do
    {:trips,
     [
       %{reload_depot: nil, clients: first.clients}
       | Enum.map(reloads, &%{reload_depot: &1.start_depot, clients: &1.clients})
     ]}
  end
end

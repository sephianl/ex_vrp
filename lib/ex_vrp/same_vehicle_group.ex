defmodule ExVrp.SameVehicleGroup do
  @moduledoc """
  A group of clients that must be served by the same vehicle.

  If multiple clients from the group are visited, they must all be on the
  same route. It is allowed to visit only a subset of the group (or none
  at all), but any visited clients must share a vehicle.

  A client may be in several groups, and each group is its own rule. When
  `a` is grouped with `b` and with `c`, then `b` and `c` share a vehicle
  only while `a` is visited: leave `a` out, and they may ride apart. A
  required `a` is always visited, so its groups always act as one.

  ## PyVRP Parity

  This module mirrors PyVRP's `SameVehicleGroup` class.

  ## Example

      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot(x: 0, y: 0)
        |> ExVrp.Model.add_client(x: 1, y: 1)
        |> ExVrp.Model.add_client(x: 2, y: 2)
        |> ExVrp.Model.add_client(x: 3, y: 3)
        |> ExVrp.Model.add_vehicle_type(num_available: 2, capacity: [100], time_windows: [{0, 28_800}])

      # Get client references
      [c1, c2, c3] = model.clients

      # Clients c1 and c2 must be on the same vehicle if visited
      model = ExVrp.Model.add_same_vehicle_group(model, [c1, c2], name: "group1")

  """

  @type t :: %__MODULE__{
          clients: [non_neg_integer()],
          name: String.t()
        }

  defstruct clients: [], name: ""

  @doc """
  Creates a new same-vehicle group.

  ## Options

  - `:clients` - List of client indices (default: `[]`)
  - `:name` - Free-form name for the group (default: `""`)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      clients: Keyword.get(opts, :clients, []),
      name: Keyword.get(opts, :name, "")
    }
  end

  @doc """
  Adds a client to the group.

  Raises `ArgumentError` if the client is already in the group.
  """
  @spec add_client(t(), non_neg_integer()) :: t()
  def add_client(%__MODULE__{clients: clients} = group, client_idx) do
    if client_idx in clients do
      raise ArgumentError, "Client already in same-vehicle group"
    end

    %{group | clients: [client_idx | clients]}
  end

  @doc """
  Clears all clients from the group.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = group) do
    %{group | clients: []}
  end

  @doc """
  Returns the number of clients in the group.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{clients: clients}), do: length(clients)

  @doc """
  Returns true if the group has no clients.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{clients: clients}), do: clients == []

  @doc """
  The groups with every two that share one of `linking_clients` merged into one, in the place
  and under the name of the first of them.

  Give it the required clients. A required client is visited in every feasible solution, so the
  groups it is in already share its vehicle, and merging them changes no solution's feasibility.
  It does tell the search: the search only asks a client's group for a routed member, so with a
  shared required client out of the solution its partners would place freely, apart, and putting
  it back would split one group whatever route it took. A shared optional client links nothing:
  with it unvisited, its partners may ride apart.
  """
  @spec merge_through([t()], MapSet.t(non_neg_integer())) :: [t()]
  def merge_through(groups, linking_clients), do: Enum.reduce(groups, [], &merge_into(&1, &2, linking_clients))

  defp merge_into(group, merged, linking_clients) do
    {linked, apart} =
      merged
      |> Enum.with_index()
      |> Enum.split_with(fn {earlier, _position} -> linked?(earlier, group, linking_clients) end)

    place_merged(Enum.map(apart, &elem(&1, 0)), linked, group)
  end

  defp place_merged(apart, [], group), do: apart ++ [group]

  defp place_merged(apart, [{first, position} | _rest] = linked, %__MODULE__{clients: clients}) do
    merged_clients = linked |> Enum.flat_map(fn {earlier, _position} -> earlier.clients end) |> Kernel.++(clients)
    List.insert_at(apart, position, %{first | clients: Enum.uniq(merged_clients)})
  end

  defp linked?(%__MODULE__{clients: clients}, %__MODULE__{clients: others}, linking_clients),
    do: Enum.any?(clients, &(&1 in others and MapSet.member?(linking_clients, &1)))
end

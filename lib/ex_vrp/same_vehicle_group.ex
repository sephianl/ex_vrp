defmodule ExVrp.SameVehicleGroup do
  @moduledoc """
  A group of clients that must be served by the same vehicle.

  If multiple clients from the group are visited, they must all be on the
  same route. It is allowed to visit only a subset of the group (or none
  at all), but any visited clients must share a vehicle.

  ## PyVRP Parity

  This module mirrors PyVRP's `SameVehicleGroup` class.

  ## Example

      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot(x: 0, y: 0)
        |> ExVrp.Model.add_client(x: 1, y: 1)
        |> ExVrp.Model.add_client(x: 2, y: 2)
        |> ExVrp.Model.add_client(x: 3, y: 3)
        |> ExVrp.Model.add_vehicle_type(num_available: 2)

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

    %{group | clients: clients ++ [client_idx]}
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
end

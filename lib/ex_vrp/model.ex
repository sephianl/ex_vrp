defmodule ExVrp.Model do
  @moduledoc """
  High-level builder for constructing VRP problems.

  The Model provides a fluent API for defining clients, depots,
  vehicle types, and routing constraints before solving.

  ## Example

      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot(x: 0, y: 0)
        |> ExVrp.Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> ExVrp.Model.add_client(x: 1, y: 1, delivery: [10])
        |> ExVrp.Model.add_client(x: 2, y: 2, delivery: [20])
        |> ExVrp.Model.add_client(x: 3, y: 1, delivery: [15])

      {:ok, solution} = ExVrp.solve(model)

  """

  alias ExVrp.Client
  alias ExVrp.ClientGroup
  alias ExVrp.Depot
  alias ExVrp.VehicleType

  @type t :: %__MODULE__{
          clients: [Client.t()],
          depots: [Depot.t()],
          vehicle_types: [VehicleType.t()],
          client_groups: [ClientGroup.t()],
          distance_matrices: [[[non_neg_integer()]]],
          duration_matrices: [[[non_neg_integer()]]]
        }

  defstruct clients: [],
            depots: [],
            vehicle_types: [],
            client_groups: [],
            distance_matrices: [],
            duration_matrices: []

  @doc """
  Creates a new empty model.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Returns the number of depots in the model.
  """
  @spec num_depots(t()) :: non_neg_integer()
  def num_depots(%__MODULE__{depots: depots}), do: length(depots)

  @doc """
  Returns the number of clients in the model.
  """
  @spec num_clients(t()) :: non_neg_integer()
  def num_clients(%__MODULE__{clients: clients}), do: length(clients)

  @doc """
  Returns the total number of vehicles in the model.
  """
  @spec num_vehicles(t()) :: non_neg_integer()
  def num_vehicles(%__MODULE__{vehicle_types: types}) do
    Enum.sum(Enum.map(types, & &1.num_available))
  end

  @doc """
  Returns the number of vehicle types in the model.
  """
  @spec num_vehicle_types(t()) :: non_neg_integer()
  def num_vehicle_types(%__MODULE__{vehicle_types: types}), do: length(types)

  @doc """
  Returns the total number of locations (depots + clients) in the model.
  """
  @spec num_locations(t()) :: non_neg_integer()
  def num_locations(%__MODULE__{depots: depots, clients: clients}) do
    length(depots) + length(clients)
  end

  @doc """
  Adds a client to the model.

  See `ExVrp.Client.new/1` for available options.

  ## Options

  - `:group` - Group index from `add_client_group/2` (optional)
  - See `ExVrp.Client.new/1` for other options

  ## Example

      model
      |> ExVrp.Model.add_client(x: 1, y: 2, delivery: [10])

      # With group assignment
      {model, group} = Model.add_client_group(model, required: false)
      model = Model.add_client(model, x: 1, y: 1, group: group)

  ## Raises

  - `ArgumentError` if group index is invalid
  - `ArgumentError` if required client is added to mutually exclusive group

  """
  @spec add_client(t(), keyword()) :: t()
  def add_client(%__MODULE__{clients: clients, depots: depots, client_groups: groups} = model, opts) do
    group_idx = Keyword.get(opts, :group)
    required = Keyword.get(opts, :required, true)

    # Validation: check group exists and required/mutually_exclusive compatibility
    groups =
      if group_idx == nil do
        groups

        # Compute client index (depots + existing clients)
      else
        group = Enum.at(groups, group_idx)

        if group == nil do
          raise ArgumentError, "Group index #{group_idx} not found in model"
        end

        if required and group.mutually_exclusive do
          raise ArgumentError, "Required client cannot be in mutually exclusive group"
        end

        client_idx = length(depots) + length(clients)

        # Update group with new client
        List.update_at(groups, group_idx, &ClientGroup.add_client(&1, client_idx))
      end

    # Create client (with group index stored)
    client = Client.new(opts)

    %{model | clients: clients ++ [client], client_groups: groups}
  end

  @doc """
  Adds a depot to the model.

  See `ExVrp.Depot.new/1` for available options.

  Note: When adding a depot after clients have been added, all client
  group indices are recalculated to account for the new depot shifting
  client indices.

  ## Example

      model
      |> ExVrp.Model.add_depot(x: 0, y: 0)

  """
  @spec add_depot(t(), keyword()) :: t()
  def add_depot(%__MODULE__{depots: depots, clients: clients, client_groups: groups} = model, opts) do
    depot = Depot.new(opts)
    new_depots = depots ++ [depot]

    # Recalculate group indices if clients exist
    new_groups =
      if clients == [] do
        groups
      else
        recalculate_group_indices(groups, clients, length(new_depots))
      end

    %{model | depots: new_depots, client_groups: new_groups}
  end

  defp recalculate_group_indices(groups, clients, num_depots) do
    # Clear all groups
    cleared = Enum.map(groups, &ClientGroup.clear/1)

    # Re-add clients to their groups with new indices
    clients
    |> Enum.with_index()
    |> Enum.reduce(cleared, fn {client, i}, acc ->
      if client.group == nil do
        acc
      else
        client_idx = num_depots + i
        List.update_at(acc, client.group, &ClientGroup.add_client(&1, client_idx))
      end
    end)
  end

  @doc """
  Adds a vehicle type to the model.

  See `ExVrp.VehicleType.new/1` for available options.

  ## Example

      model
      |> ExVrp.Model.add_vehicle_type(num_available: 3, capacity: [100])

  """
  @spec add_vehicle_type(t(), keyword()) :: t()
  def add_vehicle_type(%__MODULE__{vehicle_types: vehicle_types} = model, opts) do
    vehicle_type = VehicleType.new(opts)
    %{model | vehicle_types: vehicle_types ++ [vehicle_type]}
  end

  @doc """
  Adds a new client group to the model.

  Returns `{model, group_index}` where group_index can be passed to
  `add_client/2` to dynamically add clients to the group.

  ## Options

  - `:required` - Whether at least one client must be visited (default: `true`)
  - `:mutually_exclusive` - Whether only one client can be visited (default: `not required`)
  - `:name` - Group name for identification (default: `""`)

  ## Example

      {model, group} = Model.add_client_group(model, required: false)
      model = Model.add_client(model, x: 1, y: 1, group: group)
      model = Model.add_client(model, x: 2, y: 2, group: group)

  """
  @spec add_client_group(t(), keyword()) :: {t(), non_neg_integer()}
  def add_client_group(%__MODULE__{client_groups: groups} = model, opts \\ []) do
    group = ClientGroup.new(opts)
    group_idx = length(groups)
    {%{model | client_groups: groups ++ [group]}, group_idx}
  end

  @doc """
  Sets custom distance matrices.

  If not provided, Euclidean distances are computed from coordinates.

  ## Example

      model
      |> ExVrp.Model.set_distance_matrices([matrix1, matrix2])

  """
  @spec set_distance_matrices(t(), [[[non_neg_integer()]]]) :: t()
  def set_distance_matrices(%__MODULE__{} = model, matrices) do
    %{model | distance_matrices: matrices}
  end

  @doc """
  Sets custom duration matrices.

  If not provided, distances are used as durations.

  ## Example

      model
      |> ExVrp.Model.set_duration_matrices([matrix1, matrix2])

  """
  @spec set_duration_matrices(t(), [[[non_neg_integer()]]]) :: t()
  def set_duration_matrices(%__MODULE__{} = model, matrices) do
    %{model | duration_matrices: matrices}
  end

  @doc """
  Validates the model and returns any errors.

  Returns `:ok` if valid, `{:error, reasons}` otherwise.
  """
  @spec validate(t()) :: :ok | {:error, [String.t()]}
  def validate(%__MODULE__{} = model) do
    errors =
      []
      |> validate_has_depots(model)
      |> validate_has_vehicle_types(model)
      |> validate_capacity_dimensions(model)
      |> validate_client_time_windows(model)
      |> validate_client_service_duration(model)
      |> validate_client_demands(model)
      |> validate_client_release_times(model)
      |> validate_depot_time_windows(model)
      |> validate_vehicle_num_available(model)
      |> validate_vehicle_capacity(model)
      |> validate_vehicle_depot_indices(model)
      |> validate_vehicle_reload_depots(model)
      |> validate_matrix_dimensions(model)
      |> validate_matrix_diagonals(model)
      |> validate_client_groups(model)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  defp validate_has_depots(errors, %{depots: []}) do
    ["Model must have at least one depot" | errors]
  end

  defp validate_has_depots(errors, _model), do: errors

  defp validate_has_vehicle_types(errors, %{vehicle_types: []}) do
    ["Model must have at least one vehicle type" | errors]
  end

  defp validate_has_vehicle_types(errors, _model), do: errors

  defp validate_capacity_dimensions(errors, %{vehicle_types: []}) do
    errors
  end

  defp validate_capacity_dimensions(errors, %{clients: clients, vehicle_types: vehicle_types}) do
    dims = length(hd(vehicle_types).capacity)

    invalid_indices =
      clients
      |> Enum.with_index()
      |> Enum.filter(fn {c, _} -> length(c.delivery) != dims or length(c.pickup) != dims end)
      |> Enum.map(fn {_, i} -> i end)

    case invalid_indices do
      [] -> errors
      _ -> ["Clients #{inspect(invalid_indices)} have mismatched capacity dimensions" | errors]
    end
  end

  defp validate_client_time_windows(errors, %{clients: clients}) do
    invalid =
      clients
      |> Enum.with_index()
      |> Enum.filter(fn {c, _} -> c.tw_late < c.tw_early end)
      |> Enum.map(fn {_, i} -> i end)

    case invalid do
      [] -> errors
      _ -> ["Client time windows invalid (tw_late < tw_early) at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_client_service_duration(errors, %{clients: clients}) do
    invalid =
      clients
      |> Enum.with_index()
      |> Enum.filter(fn {c, _} -> c.service_duration < 0 end)
      |> Enum.map(fn {_, i} -> i end)

    case invalid do
      [] -> errors
      _ -> ["Negative service duration at client indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_client_demands(errors, %{clients: clients}) do
    invalid =
      clients
      |> Enum.with_index()
      |> Enum.filter(fn {c, _} -> Enum.any?(c.delivery, &(&1 < 0)) or Enum.any?(c.pickup, &(&1 < 0)) end)
      |> Enum.map(fn {_, i} -> i end)

    case invalid do
      [] -> errors
      _ -> ["Negative demand amounts at client indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_client_release_times(errors, %{clients: clients}) do
    invalid =
      clients
      |> Enum.with_index()
      |> Enum.filter(fn {c, _} -> c.release_time > c.tw_late end)
      |> Enum.map(fn {_, i} -> i end)

    case invalid do
      [] -> errors
      _ -> ["Release time > tw_late at client indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_depot_time_windows(errors, %{depots: depots}) do
    invalid =
      depots
      |> Enum.with_index()
      |> Enum.filter(fn {d, _} -> d.tw_late < d.tw_early end)
      |> Enum.map(fn {_, i} -> i end)

    case invalid do
      [] -> errors
      _ -> ["Depot time windows invalid (tw_late < tw_early) at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_vehicle_num_available(errors, %{vehicle_types: vehicle_types}) do
    invalid =
      vehicle_types
      |> Enum.with_index()
      |> Enum.filter(fn {vt, _} -> vt.num_available <= 0 end)
      |> Enum.map(fn {_, i} -> i end)

    case invalid do
      [] -> errors
      _ -> ["Vehicle type num_available must be > 0 at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_vehicle_capacity(errors, %{vehicle_types: vehicle_types}) do
    invalid =
      vehicle_types
      |> Enum.with_index()
      |> Enum.filter(fn {vt, _} -> Enum.any?(vt.capacity, &(&1 < 0)) end)
      |> Enum.map(fn {_, i} -> i end)

    case invalid do
      [] -> errors
      _ -> ["Negative vehicle capacity at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_vehicle_depot_indices(errors, %{depots: depots, vehicle_types: vehicle_types}) do
    num_depots = length(depots)

    invalid =
      vehicle_types
      |> Enum.with_index()
      |> Enum.filter(fn {vt, _} ->
        vt.start_depot >= num_depots or vt.end_depot >= num_depots
      end)
      |> Enum.map(fn {_, i} -> i end)

    case invalid do
      [] -> errors
      _ -> ["Vehicle type has invalid depot index at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_vehicle_reload_depots(errors, %{depots: depots, vehicle_types: vehicle_types}) do
    num_depots = length(depots)

    invalid =
      vehicle_types
      |> Enum.with_index()
      |> Enum.filter(fn {vt, _} ->
        Enum.any?(vt.reload_depots, &(&1 >= num_depots))
      end)
      |> Enum.map(fn {_, i} -> i end)

    case invalid do
      [] -> errors
      _ -> ["Vehicle type has invalid reload depot index at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_matrix_dimensions(errors, %{distance_matrices: [], duration_matrices: []}) do
    errors
  end

  defp validate_matrix_dimensions(errors, model) do
    %{depots: depots, clients: clients, distance_matrices: dist, duration_matrices: dur} = model
    expected_size = length(depots) + length(clients)

    errors
    |> validate_matrices(dist, expected_size, "Distance")
    |> validate_matrices(dur, expected_size, "Duration")
  end

  defp validate_matrices(errors, matrices, expected_size, name) do
    if matrices_valid?(matrices, expected_size) do
      errors
    else
      ["#{name} matrix dimensions don't match number of locations" | errors]
    end
  end

  defp matrices_valid?(matrices, expected_size) do
    Enum.all?(matrices, &matrix_valid?(&1, expected_size))
  end

  defp matrix_valid?(matrix, expected_size) when is_list(matrix) do
    length(matrix) == expected_size and Enum.all?(matrix, &row_valid?(&1, expected_size))
  end

  defp matrix_valid?(_matrix, _expected_size), do: false

  defp row_valid?(row, expected_size) when is_list(row), do: length(row) == expected_size
  defp row_valid?(_row, _expected_size), do: false

  defp validate_matrix_diagonals(errors, %{distance_matrices: [], duration_matrices: []}) do
    errors
  end

  defp validate_matrix_diagonals(errors, %{distance_matrices: dist, duration_matrices: dur}) do
    errors
    |> check_diagonal(dist, "Distance")
    |> check_diagonal(dur, "Duration")
  end

  defp check_diagonal(errors, matrices, name) do
    if Enum.any?(matrices, &has_nonzero_diagonal?/1) do
      ["#{name} matrix diagonal must be zero" | errors]
    else
      errors
    end
  end

  defp has_nonzero_diagonal?(matrix) when is_list(matrix) do
    matrix
    |> Enum.with_index()
    |> Enum.any?(fn {row, i} -> is_list(row) and Enum.at(row, i, 0) != 0 end)
  end

  defp has_nonzero_diagonal?(_), do: false

  defp validate_client_groups(errors, %{client_groups: [], clients: _clients}) do
    errors
  end

  defp validate_client_groups(errors, %{client_groups: groups, clients: clients, depots: depots}) do
    num_clients = length(clients)
    num_depots = length(depots)

    Enum.reduce(Enum.with_index(groups), errors, fn {group, idx}, acc ->
      cond do
        # Check all client indices are valid (must be >= num_depots and < num_locs)
        Enum.any?(group.clients, fn ci ->
          ci < num_depots or ci >= num_depots + num_clients
        end) ->
          ["Group #{idx} has invalid client index" | acc]

        # Required clients can't be in mutually exclusive groups
        group.mutually_exclusive and
            Enum.any?(group.clients, fn ci ->
              client_list_idx = ci - num_depots

              if client_list_idx >= 0 and client_list_idx < num_clients do
                Enum.at(clients, client_list_idx).required
              else
                false
              end
            end) ->
          ["Group #{idx}: required client in mutually exclusive group" | acc]

        true ->
          acc
      end
    end)
  end

  @doc """
  Converts the model to ProblemData for the solver.

  This is called internally by `ExVrp.solve/2`.
  """
  @spec to_problem_data(t()) :: {:ok, reference()} | {:error, term()}
  def to_problem_data(%__MODULE__{} = model) do
    case validate(model) do
      :ok -> ExVrp.Native.create_problem_data(model)
      {:error, _} = error -> error
    end
  end
end

defmodule ExVrp.Model do
  @moduledoc """
  High-level builder for constructing VRP problems.

  The Model provides a fluent API for defining depots, vehicle types,
  clients, and routing constraints. A model must have at least one depot
  and one vehicle type before it can be solved.

  ## Basic Example

      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot(x: 0, y: 0)
        |> ExVrp.Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> ExVrp.Model.add_client(x: 1, y: 1, delivery: [10])
        |> ExVrp.Model.add_client(x: 2, y: 2, delivery: [20])
        |> ExVrp.Model.add_client(x: 3, y: 1, delivery: [15])

      {:ok, result} = ExVrp.solve(model)

  ## Custom Distance/Duration Matrices

  By default, Euclidean distances are computed from coordinates. You can
  provide custom matrices instead (one per vehicle profile):

      # Matrix rows/columns: [depot, client1, client2, ...]
      distances = [
        [0, 100, 200],
        [100, 0, 150],
        [200, 150, 0]
      ]

      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot(x: 0, y: 0)
        |> ExVrp.Model.add_client(x: 1, y: 0, delivery: [10])
        |> ExVrp.Model.add_client(x: 2, y: 0, delivery: [20])
        |> ExVrp.Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> ExVrp.Model.set_distance_matrices([distances])
        |> ExVrp.Model.set_duration_matrices([distances])

  ## Multi-Dimensional Capacity

  Vehicles and clients can have multiple capacity dimensions (e.g. weight and volume):

      model
      |> ExVrp.Model.add_vehicle_type(num_available: 3, capacity: [1000, 50])
      |> ExVrp.Model.add_client(x: 1, y: 1, delivery: [200, 10])

  ## Client Groups

  Client groups allow mutually exclusive alternatives — only one client from
  the group will be visited:

      {model, group} = ExVrp.Model.add_client_group(model, required: false)
      model =
        model
        |> ExVrp.Model.add_client(x: 1, y: 1, group: group, required: false, prize: 100)
        |> ExVrp.Model.add_client(x: 2, y: 2, group: group, required: false, prize: 150)

  ## Same-Vehicle Groups

  Force specific clients onto the same route:

      [c1, c2] = model.clients
      model = ExVrp.Model.add_same_vehicle_group(model, [c1, c2])

  ## Validation

  Models are validated automatically before solving. You can also validate
  explicitly:

      case ExVrp.Model.validate(model) do
        :ok -> :ready
        {:error, reasons} -> IO.inspect(reasons)
      end

  """

  alias ExVrp.Client
  alias ExVrp.ClientGroup
  alias ExVrp.Depot
  alias ExVrp.SameVehicleGroup
  alias ExVrp.VehicleGroup
  alias ExVrp.VehicleType

  @type t :: %__MODULE__{
          clients: [Client.t()],
          depots: [Depot.t()],
          vehicle_types: [VehicleType.t()],
          client_groups: [ClientGroup.t()],
          same_vehicle_groups: [SameVehicleGroup.t()],
          vehicle_groups: [VehicleGroup.t()],
          distance_matrices: [[[non_neg_integer()]]],
          duration_matrices: [[[non_neg_integer()]]]
        }

  defstruct clients: [],
            depots: [],
            vehicle_types: [],
            client_groups: [],
            same_vehicle_groups: [],
            vehicle_groups: [],
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
  def add_depot(
        %__MODULE__{depots: depots, clients: clients, client_groups: groups, same_vehicle_groups: svg} = model,
        opts
      ) do
    depot = Depot.new(opts)
    new_depots = depots ++ [depot]

    # Recalculate group indices if clients exist
    new_groups =
      if clients == [] do
        groups
      else
        recalculate_group_indices(groups, clients, length(new_depots))
      end

    # Rebuild same-vehicle groups with shifted client indices
    new_svg =
      Enum.map(svg, fn group ->
        new_clients = Enum.map(group.clients, &(&1 + 1))
        %{group | clients: new_clients}
      end)

    %{model | depots: new_depots, client_groups: new_groups, same_vehicle_groups: new_svg}
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
  Adds a same-vehicle constraint group to the model.

  All clients in this group that are visited must be served by the same
  vehicle. It is allowed to visit only a subset of the group (or none at
  all), but any visited clients must share a route.

  ## Parameters

  - `model` - The model to add the group to
  - `clients` - List of Client structs that must be served by the same vehicle

  ## Options

  - `:name` - Free-form name for the group (default: `""`)

  ## Returns

  The updated model with the new same-vehicle group added.

  ## Example

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_client(x: 2, y: 2)
        |> Model.add_vehicle_type(num_available: 2)

      [c1, c2] = model.clients
      model = Model.add_same_vehicle_group(model, [c1, c2], name: "group1")

  ## Raises

  - `ArgumentError` if any client is not in the model
  """
  @spec add_same_vehicle_group(t(), [Client.t()], keyword()) :: t()
  def add_same_vehicle_group(%__MODULE__{} = model, clients, opts \\ []) do
    name = Keyword.get(opts, :name, "")
    num_depots = length(model.depots)

    client_indices =
      Enum.map(clients, fn client ->
        idx = Enum.find_index(model.clients, &(&1 == client))

        if is_nil(idx) do
          raise ArgumentError, "Client not in model"
        end

        # Client indices are offset by the number of depots
        num_depots + idx
      end)

    group = %SameVehicleGroup{clients: client_indices, name: name}
    %{model | same_vehicle_groups: model.same_vehicle_groups ++ [group]}
  end

  @doc """
  Adds a vehicle group to the model.

  Vehicle groups represent vehicle types that belong to the same physical
  vehicle/driver. The solver enforces a minimum time gap between consecutive
  routes assigned to vehicle types in the same group.

  ## Options

  - `:vehicle_types` - List of vehicle type indices (0-based) belonging to this group (required)
  - `:min_gap` - Minimum time gap between consecutive routes (default: 0)

  ## Example

      model
      |> Model.add_vehicle_type(num_available: 1, capacity: [100], tw_early: 0, tw_late: 500)
      |> Model.add_vehicle_type(num_available: 1, capacity: [100], tw_early: 600, tw_late: 1000)
      |> Model.add_vehicle_group(vehicle_types: [0, 1], min_gap: 100)

  """
  @spec add_vehicle_group(t(), keyword()) :: t()
  def add_vehicle_group(%__MODULE__{} = model, opts) do
    vehicle_type_indices = Keyword.fetch!(opts, :vehicle_types)
    min_gap = Keyword.get(opts, :min_gap, 0)

    group = %VehicleGroup{vehicle_type_indices: vehicle_type_indices, min_gap: min_gap}
    %{model | vehicle_groups: model.vehicle_groups ++ [group]}
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
      |> validate_vehicle_forbidden_windows(model)
      |> validate_matrix_dimensions(model)
      |> validate_matrix_diagonals(model)
      |> validate_client_groups(model)
      |> validate_same_vehicle_groups(model)
      |> validate_vehicle_groups(model)

    case errors do
      [] -> :ok
      _errors -> {:error, errors}
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
      |> Enum.filter(fn {c, _idx} -> length(c.delivery) != dims or length(c.pickup) != dims end)
      |> Enum.map(fn {_client, i} -> i end)

    case invalid_indices do
      [] -> errors
      _indices -> ["Clients #{inspect(invalid_indices)} have mismatched capacity dimensions" | errors]
    end
  end

  defp validate_client_time_windows(errors, %{clients: clients}) do
    invalid =
      clients
      |> Enum.with_index()
      |> Enum.filter(fn {c, _idx} -> c.tw_late < c.tw_early end)
      |> Enum.map(fn {_client, i} -> i end)

    case invalid do
      [] -> errors
      _indices -> ["Client time windows invalid (tw_late < tw_early) at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_client_service_duration(errors, %{clients: clients}) do
    invalid =
      clients
      |> Enum.with_index()
      |> Enum.filter(fn {c, _idx} -> c.service_duration < 0 end)
      |> Enum.map(fn {_client, i} -> i end)

    case invalid do
      [] -> errors
      _indices -> ["Negative service duration at client indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_client_demands(errors, %{clients: clients}) do
    invalid =
      clients
      |> Enum.with_index()
      |> Enum.filter(fn {c, _idx} -> Enum.any?(c.delivery, &(&1 < 0)) or Enum.any?(c.pickup, &(&1 < 0)) end)
      |> Enum.map(fn {_client, i} -> i end)

    case invalid do
      [] -> errors
      _indices -> ["Negative demand amounts at client indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_client_release_times(errors, %{clients: clients}) do
    invalid =
      clients
      |> Enum.with_index()
      |> Enum.filter(fn {c, _idx} -> c.release_time > c.tw_late end)
      |> Enum.map(fn {_client, i} -> i end)

    case invalid do
      [] -> errors
      _indices -> ["Release time > tw_late at client indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_depot_time_windows(errors, %{depots: depots}) do
    invalid =
      depots
      |> Enum.with_index()
      |> Enum.filter(fn {d, _idx} -> d.tw_late < d.tw_early end)
      |> Enum.map(fn {_depot, i} -> i end)

    case invalid do
      [] -> errors
      _indices -> ["Depot time windows invalid (tw_late < tw_early) at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_vehicle_num_available(errors, %{vehicle_types: vehicle_types}) do
    invalid =
      vehicle_types
      |> Enum.with_index()
      |> Enum.filter(fn {vt, _idx} -> vt.num_available <= 0 end)
      |> Enum.map(fn {_vt, i} -> i end)

    case invalid do
      [] -> errors
      _indices -> ["Vehicle type num_available must be > 0 at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_vehicle_capacity(errors, %{vehicle_types: vehicle_types}) do
    invalid =
      vehicle_types
      |> Enum.with_index()
      |> Enum.filter(fn {vt, _idx} -> Enum.any?(vt.capacity, &(&1 < 0)) end)
      |> Enum.map(fn {_vt, i} -> i end)

    case invalid do
      [] -> errors
      _indices -> ["Negative vehicle capacity at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_vehicle_depot_indices(errors, %{depots: depots, vehicle_types: vehicle_types}) do
    num_depots = length(depots)

    invalid =
      vehicle_types
      |> Enum.with_index()
      |> Enum.filter(fn {vt, _idx} ->
        vt.start_depot >= num_depots or vt.end_depot >= num_depots
      end)
      |> Enum.map(fn {_vt, i} -> i end)

    case invalid do
      [] -> errors
      _indices -> ["Vehicle type has invalid depot index at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_vehicle_reload_depots(errors, %{depots: depots, vehicle_types: vehicle_types}) do
    num_depots = length(depots)

    invalid =
      vehicle_types
      |> Enum.with_index()
      |> Enum.filter(fn {vt, _idx} ->
        Enum.any?(vt.reload_depots, &(&1 >= num_depots))
      end)
      |> Enum.map(fn {_vt, i} -> i end)

    case invalid do
      [] -> errors
      _indices -> ["Vehicle type has invalid reload depot index at indices #{inspect(invalid)}" | errors]
    end
  end

  defp validate_vehicle_forbidden_windows(errors, %{vehicle_types: vehicle_types}) do
    invalid =
      vehicle_types
      |> Enum.with_index()
      |> Enum.filter(fn {vt, _idx} ->
        Enum.any?(vt.forbidden_windows, fn {s, e} ->
          s >= e or s < vt.tw_early or e > vt.tw_late
        end)
      end)
      |> Enum.map(fn {_vt, i} -> i end)

    case invalid do
      [] ->
        errors

      _indices ->
        [
          "Vehicle forbidden windows invalid (must have start < end and be within [tw_early, tw_late]) at indices #{inspect(invalid)}"
          | errors
        ]
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

  defp has_nonzero_diagonal?(_matrix), do: false

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

  defp validate_same_vehicle_groups(errors, %{same_vehicle_groups: []}) do
    errors
  end

  defp validate_same_vehicle_groups(errors, %{same_vehicle_groups: groups, clients: clients, depots: depots}) do
    num_clients = length(clients)
    num_depots = length(depots)

    Enum.reduce(Enum.with_index(groups), errors, fn {group, idx}, acc ->
      cond do
        # Empty same-vehicle groups are not allowed
        group.clients == [] ->
          ["Same-vehicle group #{idx} is empty" | acc]

        # Check all client indices are valid (must be >= num_depots and < num_locs)
        Enum.any?(group.clients, fn ci ->
          ci < num_depots or ci >= num_depots + num_clients
        end) ->
          ["Same-vehicle group #{idx} has invalid client index" | acc]

        # Check for duplicate clients within the group
        length(group.clients) != length(Enum.uniq(group.clients)) ->
          ["Same-vehicle group #{idx} has duplicate clients" | acc]

        true ->
          acc
      end
    end)
  end

  defp validate_vehicle_groups(errors, %{vehicle_groups: []}), do: errors

  defp validate_vehicle_groups(errors, %{vehicle_groups: groups, vehicle_types: vehicle_types}) do
    num_vehicle_types = length(vehicle_types)

    Enum.reduce(Enum.with_index(groups), errors, fn {group, idx}, acc ->
      cond do
        group.vehicle_type_indices == [] ->
          ["Vehicle group #{idx} is empty" | acc]

        Enum.any?(group.vehicle_type_indices, fn i -> i >= num_vehicle_types end) ->
          ["Vehicle group #{idx} has invalid vehicle type index" | acc]

        group.min_gap < 0 ->
          ["Vehicle group #{idx} has negative min_gap" | acc]

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
      :ok ->
        model = merge_vehicle_group_shifts(model)
        ExVrp.Native.create_problem_data(model)

      {:error, _reason} = error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Vehicle group shift merging
  # ---------------------------------------------------------------------------

  # Merges vehicle types in the same vehicle group into a single type with
  # forbidden_windows. This converts separate shift vehicle types (e.g. morning
  # shift [0,500] and afternoon shift [600,1000]) into one type with
  # time_windows: [{0,500},{600,1000}] which auto-generates forbidden_windows.
  # The solver then enforces shift gaps during search rather than needing
  # post-processing.
  defp merge_vehicle_group_shifts(%{vehicle_groups: []} = model), do: model

  defp merge_vehicle_group_shifts(model) do
    model.vehicle_groups
    |> Enum.reduce(model, &merge_single_group/2)
    |> then(fn m -> %{m | vehicle_groups: []} end)
  end

  defp merge_single_group(%{vehicle_type_indices: indices}, model) when length(indices) < 2, do: model

  defp merge_single_group(%{vehicle_type_indices: indices, min_gap: min_gap}, model) do
    types = Enum.map(indices, &Enum.at(model.vehicle_types, &1))
    sorted = Enum.sort_by(types, & &1.tw_early)
    time_windows = Enum.map(sorted, fn vt -> {vt.tw_early, vt.tw_late} end)
    base = hd(sorted)

    # Only merge shifts that have gaps AND can actually do inter-shift reloads
    if has_gaps?(time_windows) and base.reload_depots != [] do
      do_merge(model, sorted, time_windows, indices, min_gap)
    else
      model
    end
  end

  defp has_gaps?(time_windows) do
    time_windows
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [{_start, prev_end}, {next_start, _end}] -> next_start > prev_end end)
  end

  defp do_merge(model, sorted, time_windows, indices, min_gap) do
    base = hd(sorted)

    tw_early = elem(hd(time_windows), 0)
    tw_late = elem(List.last(time_windows), 1)
    span = tw_late - tw_early

    original_max = sorted |> Enum.map(& &1.max_reloads) |> max_reloads_value()
    num_shifts = length(sorted)

    # Check if a reload from the earliest possible time can reach before tw_late,
    # accounting for forbidden windows that may delay the vehicle further.
    can_reload = earliest_after_reload(tw_early, min_gap, time_windows) < tw_late

    merged_max_reloads =
      if can_reload do
        case original_max do
          :infinity -> :infinity
          n -> n + num_shifts - 1
        end
      else
        case original_max do
          :infinity -> 0
          n -> n
        end
      end

    merged =
      VehicleType.new(
        num_available: base.num_available,
        capacity: base.capacity,
        start_depot: base.start_depot,
        end_depot: base.end_depot,
        fixed_cost: base.fixed_cost,
        time_windows: time_windows,
        shift_duration: span,
        max_distance: base.max_distance,
        unit_distance_cost: base.unit_distance_cost,
        unit_duration_cost: base.unit_duration_cost,
        profile: base.profile,
        start_late: base.start_late,
        max_overtime: base.max_overtime,
        unit_overtime_cost: base.unit_overtime_cost,
        reload_depots: base.reload_depots,
        max_reloads: merged_max_reloads,
        initial_load: base.initial_load,
        name: base.name
      )

    sorted_indices = Enum.sort(indices)
    [first_idx | rest_indices] = sorted_indices

    vehicle_types =
      model.vehicle_types
      |> List.replace_at(first_idx, merged)
      |> zero_out_types(rest_indices)

    %{model | vehicle_types: vehicle_types}
  end

  # Computes the earliest time a vehicle could start a second trip after
  # completing one at tw_early and reloading for min_gap seconds.
  # Accounts for forbidden windows that may delay the vehicle further.
  defp earliest_after_reload(tw_early, min_gap, time_windows) do
    after_reload = tw_early + min_gap
    forbidden_windows = compute_forbidden_windows(time_windows)
    advance_past_forbidden(after_reload, forbidden_windows)
  end

  defp compute_forbidden_windows(time_windows) do
    time_windows
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{_s, prev_end}, {next_start, _e}] ->
      if next_start > prev_end, do: [{prev_end, next_start}], else: []
    end)
  end

  defp advance_past_forbidden(time, forbidden_windows) do
    Enum.reduce(forbidden_windows, time, fn {fw_start, fw_end}, t ->
      if t >= fw_start and t < fw_end, do: fw_end, else: t
    end)
  end

  defp zero_out_types(types, indices) do
    Enum.reduce(indices, types, fn idx, acc ->
      List.update_at(acc, idx, &%{&1 | num_available: 0})
    end)
  end

  defp max_reloads_value(values) do
    if :infinity in values, do: :infinity, else: Enum.max(values)
  end
end

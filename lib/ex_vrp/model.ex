defmodule ExVrp.Model do
  @moduledoc """
  High-level builder for constructing VRP problems.

  The Model provides a fluent API for defining depots, vehicle types,
  clients, and routing constraints. A model must have at least one depot
  and one vehicle type before it can be solved.

  ## Basic Example

      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot([])
        |> ExVrp.Model.add_vehicle_type(num_available: 2, capacity: [100], time_windows: [{0, 28_800}])
        |> ExVrp.Model.add_client(delivery: [10])
        |> ExVrp.Model.add_client(delivery: [20])
        |> ExVrp.Model.add_client(delivery: [15])
        |> ExVrp.Model.set_euclidean_matrices([{0, 0}, {1, 1}, {2, 2}, {3, 1}])

      {:ok, result} = ExVrp.solve(model)

  ## Distance and Duration Matrices

  Locations carry no coordinates: the matrices are the solver's only notion of
  distance, and a model without one will not validate. Supply them directly
  (one per vehicle profile), or derive them from coordinates with
  `set_euclidean_matrices/2`:

      # Matrix rows/columns: [depot, client1, client2, ...]
      distances = [
        [0, 100, 200],
        [100, 0, 150],
        [200, 150, 0]
      ]

      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot([])
        |> ExVrp.Model.add_client(delivery: [10])
        |> ExVrp.Model.add_client(delivery: [20])
        |> ExVrp.Model.add_vehicle_type(num_available: 2, capacity: [100], time_windows: [{0, 28_800}])
        |> ExVrp.Model.set_distance_matrices([distances])
        |> ExVrp.Model.set_duration_matrices([distances])

  ## Multi-Dimensional Capacity

  Vehicles and clients can have multiple capacity dimensions (e.g. weight and volume):

      model
      |> ExVrp.Model.add_vehicle_type(num_available: 3, capacity: [1000, 50], time_windows: [{0, 28_800}])
      |> ExVrp.Model.add_client(delivery: [200, 10])

  ## Client Groups

  Client groups allow mutually exclusive alternatives — only one client from
  the group will be visited:

      {model, group} = ExVrp.Model.add_client_group(model, required: false)
      model =
        model
        |> ExVrp.Model.add_client(group: group, required: false, prize: 100)
        |> ExVrp.Model.add_client(group: group, required: false, prize: 150)

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
  alias ExVrp.VehicleType

  @type t :: %__MODULE__{
          clients: [Client.t()],
          depots: [Depot.t()],
          vehicle_types: [VehicleType.t()],
          client_groups: [ClientGroup.t()],
          same_vehicle_groups: [SameVehicleGroup.t()],
          distance_matrices: [[[non_neg_integer()]]],
          duration_matrices: [[[non_neg_integer()]]],
          penalties: [[non_neg_integer()]],
          forbidden: [[non_neg_integer()]]
        }

  defstruct clients: [],
            depots: [],
            vehicle_types: [],
            client_groups: [],
            same_vehicle_groups: [],
            distance_matrices: [],
            duration_matrices: [],
            penalties: [],
            forbidden: []

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
    Enum.sum_by(types, & &1.num_available)
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
      |> ExVrp.Model.add_client(delivery: [10])

      # With group assignment
      {model, group} = Model.add_client_group(model, required: false)
      model = Model.add_client(model, group: group)

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
      |> ExVrp.Model.add_depot([])

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
    |> Stream.with_index()
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
      |> ExVrp.Model.add_vehicle_type(num_available: 3, capacity: [100], time_windows: [{0, 28_800}])

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
  - `clients` - The clients that must be served by the same vehicle, given
    either as `Client` structs or as zero-based client indices

  **Prefer indices.** Structs are resolved by structural equality, so two
  clients that happen to carry identical data cannot be told apart: the group
  binds whichever equal clients are found first, which may not be the ones the
  caller meant. A caller that already knows its indices should pass them and
  avoid the ambiguity entirely.

  ## Options

  - `:name` - Free-form name for the group (default: `""`)

  ## Returns

  The updated model with the new same-vehicle group added.

  ## Example

      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(delivery: [10])
        |> Model.add_client(delivery: [20])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100], time_windows: [{0, 28_800}])

      model = Model.add_same_vehicle_group(model, [0, 1], name: "group1")

  ## Raises

  - `ArgumentError` if a client given as a struct is not in the model
  """
  @spec add_same_vehicle_group(t(), [Client.t()] | [non_neg_integer()], keyword()) :: t()
  def add_same_vehicle_group(%__MODULE__{} = model, clients, opts \\ []) do
    name = Keyword.get(opts, :name, "")
    num_depots = length(model.depots)

    client_indices =
      clients
      |> resolve_group_indices(model.clients)
      |> Enum.map(&(num_depots + &1))

    group = %SameVehicleGroup{clients: client_indices, name: name}
    %{model | same_vehicle_groups: model.same_vehicle_groups ++ [group]}
  end

  defp resolve_group_indices([first | _rest_of_clients] = clients, _model_clients) when is_integer(first), do: clients

  defp resolve_group_indices(clients, model_clients) do
    {indices, _taken} = Enum.map_reduce(clients, MapSet.new(), &resolve_client(&1, &2, model_clients))
    indices
  end

  defp resolve_client(client, taken, clients) do
    idx =
      clients
      |> Enum.with_index()
      |> Enum.find_value(fn {candidate, idx} ->
        if candidate == client and not MapSet.member?(taken, idx), do: idx
      end)

    if is_nil(idx) do
      raise ArgumentError, "Client not in model"
    end

    {idx, MapSet.put(taken, idx)}
  end

  @doc """
  Sets custom distance matrices.

  A model must carry at least one distance matrix before it can be solved;
  `validate/1` rejects a model without one.

  ## Example

      model
      |> ExVrp.Model.set_distance_matrices([matrix1, matrix2])

  """
  @spec set_distance_matrices(t(), [[[non_neg_integer()]]]) :: t()
  def set_distance_matrices(%__MODULE__{} = model, matrices) do
    %{model | distance_matrices: matrices}
  end

  @doc """
  Sets both matrices to the rounded Euclidean distances between `coordinates`,
  taking durations to equal distances.

  Coordinates are `{x, y}` tuples in location order — depots first, then
  clients — and are used only to derive the matrices. Locations themselves do
  not carry coordinates; the matrices are the solver's only notion of distance.

  ## Example

      model
      |> ExVrp.Model.set_euclidean_matrices([{0, 0}, {1, 1}, {2, 0}])

  """
  @spec set_euclidean_matrices(t(), [{number(), number()}]) :: t()
  def set_euclidean_matrices(%__MODULE__{} = model, coordinates) do
    matrix = for from <- coordinates, do: for(to <- coordinates, do: euclidean(from, to))

    %{model | distance_matrices: [matrix], duration_matrices: [matrix]}
  end

  defp euclidean({x1, y1}, {x2, y2}) do
    dx = x2 - x1
    dy = y2 - y1
    round(:math.sqrt(dx * dx + dy * dy))
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
  Sets per-profile, per-location penalties.

  One list per routing profile, each holding one cost per location in the
  same order the matrices use: depots first, then clients. A penalty is
  charged once for each visited location, so it is a per-client cost rather
  than a per-leg one.

  Depot entries must be zero — use `Depot`'s `reload_cost` to price a reload.
  A nonzero depot penalty is rejected when the model is solved.

  Defaults to no penalties when left unset.

  ## Example

      model
      |> ExVrp.Model.set_penalties([[0, 500, 0]])

  """
  @spec set_penalties(t(), [[non_neg_integer()]]) :: t()
  def set_penalties(%__MODULE__{} = model, penalties) do
    %{model | penalties: penalties}
  end

  @doc """
  Sets per-profile forbidden locations.

  One list per routing profile, each holding the location indices that
  vehicles on that profile must never visit. Local search prunes these
  rather than costing them, so a forbidden location is a hard exclusion —
  use `set_penalties/2` when the intent is merely expensive.

  Works whatever the profile count, single-profile models included. Indices
  must name clients: a vehicle starts and ends at its depot regardless, so
  forbidding a depot is rejected rather than quietly doing nothing.

  `ExVrp.Solution.num_forbidden_visits/1` reports violations, and is zero on
  any solution the solver produced.

  Defaults to nothing forbidden when left unset.

  ## Example

      model
      |> ExVrp.Model.set_forbidden([[1, 2]])

  """
  @spec set_forbidden(t(), [[non_neg_integer()]]) :: t()
  def set_forbidden(%__MODULE__{} = model, forbidden) do
    %{model | forbidden: forbidden}
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
      |> validate_has_distance_matrix(model)
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
      |> validate_penalties(model)
      |> validate_forbidden(model)

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

  defp validate_has_distance_matrix(errors, %{distance_matrices: []}) do
    ["Model must have at least one distance matrix — see set_distance_matrices/2 or set_euclidean_matrices/2" | errors]
  end

  defp validate_has_distance_matrix(errors, _model), do: errors

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

  defp validate_penalties(errors, %{penalties: []}), do: errors

  defp validate_penalties(errors, model) do
    errors
    |> validate_per_profile_count(model.penalties, model, "penalty")
    |> validate_penalty_shape(model)
    |> validate_penalty_values(model)
    |> validate_depot_penalties_zero(model)
  end

  defp validate_penalty_shape(errors, model) do
    expected_size = num_locations(model)

    if Enum.all?(model.penalties, &(is_list(&1) and length(&1) == expected_size)) do
      errors
    else
      ["Each penalty list must hold one cost per location" | errors]
    end
  end

  defp validate_penalty_values(errors, model) do
    if Enum.all?(model.penalties, fn row -> Enum.all?(row, &non_neg_integer?/1) end) do
      errors
    else
      ["Penalties must be non-negative integers" | errors]
    end
  end

  defp validate_depot_penalties_zero(errors, model) do
    num_depots = length(model.depots)
    depot_entries = Enum.flat_map(model.penalties, &Enum.take(&1, num_depots))

    if Enum.all?(depot_entries, &(&1 == 0)) do
      errors
    else
      ["Depot penalties must be zero — use a depot's reload_cost instead" | errors]
    end
  end

  defp validate_forbidden(errors, %{forbidden: []}), do: errors

  defp validate_forbidden(errors, model) do
    errors
    |> validate_per_profile_count(model.forbidden, model, "forbidden")
    |> validate_forbidden_indices(model)
  end

  defp validate_forbidden_indices(errors, model) do
    first_client = length(model.depots)
    last = num_locations(model) - 1

    valid? =
      Enum.all?(model.forbidden, fn row ->
        is_list(row) and Enum.all?(row, &(is_integer(&1) and &1 >= first_client and &1 <= last))
      end)

    if valid? do
      errors
    else
      [
        "Forbidden location indices must be client indices within #{first_client}..#{last} — a depot cannot be forbidden"
        | errors
      ]
    end
  end

  defp validate_per_profile_count(errors, lists, model, name) do
    expected = num_profiles(model)

    if length(lists) == expected do
      errors
    else
      ["Expected one #{name} list per routing profile (#{expected})" | errors]
    end
  end

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0

  defp num_profiles(%{distance_matrices: [], vehicle_types: vehicle_types}) do
    Enum.reduce(vehicle_types, 1, &max(&1.profile + 1, &2))
  end

  defp num_profiles(%{distance_matrices: matrices}), do: length(matrices)

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
    row_tuples = Enum.map(matrix, fn row -> if is_list(row), do: List.to_tuple(row) end)

    row_tuples
    |> Stream.with_index()
    |> Enum.any?(fn
      {nil, _i} -> false
      {row_tuple, i} -> elem(row_tuple, i) != 0
    end)
  end

  defp has_nonzero_diagonal?(_matrix), do: false

  defp validate_client_groups(errors, %{client_groups: [], clients: _clients}) do
    errors
  end

  defp validate_client_groups(errors, %{client_groups: groups, clients: clients, depots: depots}) do
    num_clients = length(clients)
    num_depots = length(depots)

    clients_tuple = List.to_tuple(clients)

    groups
    |> Stream.with_index()
    |> Enum.reduce(errors, fn {group, idx}, acc ->
      cond do
        Enum.any?(group.clients, fn ci ->
          ci < num_depots or ci >= num_depots + num_clients
        end) ->
          ["Group #{idx} has invalid client index" | acc]

        group.mutually_exclusive and
            Enum.any?(group.clients, fn ci ->
              client_list_idx = ci - num_depots

              if client_list_idx >= 0 and client_list_idx < num_clients do
                elem(clients_tuple, client_list_idx).required
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

    groups
    |> Stream.with_index()
    |> Enum.reduce(errors, fn {group, idx}, acc ->
      cond do
        group.clients == [] ->
          ["Same-vehicle group #{idx} is empty" | acc]

        Enum.any?(group.clients, fn ci ->
          ci < num_depots or ci >= num_depots + num_clients
        end) ->
          ["Same-vehicle group #{idx} has invalid client index" | acc]

        length(group.clients) != length(Enum.uniq(group.clients)) ->
          ["Same-vehicle group #{idx} has duplicate clients" | acc]

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
        ExVrp.Native.create_problem_data(model)

      {:error, _reason} = error ->
        error
    end
  end
end

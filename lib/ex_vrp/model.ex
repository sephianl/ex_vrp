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

  ## Shipments

  Pick goods up at one client and drop them off at another, later on the same
  trip (see `ExVrp.Shipment`):

      model =
        model
        |> ExVrp.Model.add_client(tw_early: 0, tw_late: 3_600)
        |> ExVrp.Model.add_client(tw_early: 7_200, tw_late: 10_800)
        |> ExVrp.Model.add_shipment(0, 1, [25])

  ## Validation

  Models are validated automatically before solving. You can also validate
  explicitly:

      case ExVrp.Model.validate(model) do
        :ok -> :ready
        {:error, reasons} -> IO.inspect(reasons)
      end

  """

  alias ExVrp.Breaks
  alias ExVrp.Client
  alias ExVrp.ClientGroup
  alias ExVrp.Depot
  alias ExVrp.Matrix
  alias ExVrp.SameVehicleGroup
  alias ExVrp.Shipment
  alias ExVrp.VehicleType

  @type profile :: %{
          matrix: non_neg_integer(),
          override_row: nil | {non_neg_integer(), Matrix.row(), Matrix.row()}
        }

  @type t :: %__MODULE__{
          clients: [Client.t()],
          depots: [Depot.t()],
          vehicle_types: [VehicleType.t()],
          client_groups: [ClientGroup.t()],
          same_vehicle_groups: [SameVehicleGroup.t()],
          shipments: [Shipment.t()],
          distance_matrices: [Matrix.t()],
          duration_matrices: [Matrix.t()],
          profiles: [profile()],
          penalties: [[non_neg_integer()]],
          forbidden: [[non_neg_integer()]],
          vehicle_locks: [map()]
        }

  defstruct clients: [],
            depots: [],
            vehicle_types: [],
            client_groups: [],
            same_vehicle_groups: [],
            shipments: [],
            distance_matrices: [],
            duration_matrices: [],
            profiles: [],
            penalties: [],
            forbidden: [],
            vehicle_locks: []

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
        %__MODULE__{
          depots: depots,
          clients: clients,
          client_groups: groups,
          same_vehicle_groups: svg,
          shipments: shipments
        } = model,
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

    new_shipments = Enum.map(shipments, &%{&1 | pickup: &1.pickup + 1, delivery: &1.delivery + 1})

    %{model | depots: new_depots, client_groups: new_groups, same_vehicle_groups: new_svg, shipments: new_shipments}
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

  @doc """
  Ties two clients into a shipment: goods collected at `pickup` and dropped
  off at `delivery`, taking up `amount` (one entry per load dimension) in
  between. See `ExVrp.Shipment` for what the solver guarantees.

  `pickup` and `delivery` are `Client` structs or zero-based client indices,
  as for `add_same_vehicle_group/3`, and the same advice holds: prefer
  indices. Each keeps its own prize and `required` flag; a required delivery
  needs a required pickup.

  ## Example

      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(tw_late: 3_600)
        |> Model.add_client(tw_early: 7_200)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_shipment(0, 1, [25])

  ## Raises

  - `ArgumentError` if a client given as a struct is not in the model
  """
  @spec add_shipment(
          t(),
          Client.t() | non_neg_integer(),
          Client.t() | non_neg_integer(),
          [non_neg_integer()]
        ) :: t()
  def add_shipment(%__MODULE__{} = model, pickup, delivery, amount) do
    num_depots = length(model.depots)
    [pickup_idx, delivery_idx] = resolve_group_indices([pickup, delivery], model.clients)

    shipment = %Shipment{pickup: num_depots + pickup_idx, delivery: num_depots + delivery_idx, amount: amount}
    %{model | shipments: model.shipments ++ [shipment]}
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

  A matrix is nested lists of rows, or one binary of little-endian signed
  64-bit integers in row-major order (see `ExVrp.Matrix`). The solver copies a
  binary in without walking it, so prefer it for large matrices.

  ## Example

      model
      |> ExVrp.Model.set_distance_matrices([matrix1, matrix2])

  """
  @spec set_distance_matrices(t(), [Matrix.t()]) :: t()
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
  Sets custom duration matrices, in either form `set_distance_matrices/2`
  takes.

  A model needs one duration matrix per distance matrix; `validate/1` rejects
  it otherwise. To travel at one distance unit per time unit, pass the
  distance matrices here too, as `set_euclidean_matrices/2` does.

  ## Example

      model
      |> ExVrp.Model.set_duration_matrices([matrix1, matrix2])

  """
  @spec set_duration_matrices(t(), [Matrix.t()]) :: t()
  def set_duration_matrices(%__MODULE__{} = model, matrices) do
    %{model | duration_matrices: matrices}
  end

  @doc """
  Sets the routing profiles a vehicle type's `:profile` indexes.

  Each profile reads the distance and duration matrices at index `:matrix`,
  and, when `:override_row` is `{row, distances, durations}`, takes row `row`
  of both from those two rows instead. Rows come in either form a matrix does.
  Profiles that differ only in one row, such as a depot row dated at each
  vehicle's departure hour, then share their matrices instead of each carrying
  a full copy, which keeps a model with many such profiles small.

  Penalties and forbidden locations stay one list per profile. Defaults to
  one profile per matrix pair, overriding nothing, when left unset.

  ## Example

      model
      |> ExVrp.Model.set_profiles([
        %{matrix: 0, override_row: nil},
        %{matrix: 0, override_row: {0, [0, 120, 300], [0, 60, 150]}}
      ])

  """
  @spec set_profiles(t(), [profile()]) :: t()
  def set_profiles(%__MODULE__{} = model, profiles) do
    %{model | profiles: profiles}
  end

  @doc """
  The distance matrix `profile` reads, as nested lists, with its override row
  in place.

  Returns `{:error, reason}` when the model has no such profile, or the
  profile names a matrix the model does not have.
  """
  @spec distance_matrix(t(), non_neg_integer()) :: {:ok, [[integer()]]} | {:error, String.t()}
  def distance_matrix(%__MODULE__{} = model, profile) when is_integer(profile) and profile >= 0 do
    profile_matrix(model, model.distance_matrices, profile, &elem(&1, 1))
  end

  @doc """
  The duration matrix `profile` reads, as nested lists, with its override row
  in place.

  Returns `{:error, reason}` when the model has no such profile, or the
  profile names a matrix the model does not have.
  """
  @spec duration_matrix(t(), non_neg_integer()) :: {:ok, [[integer()]]} | {:error, String.t()}
  def duration_matrix(%__MODULE__{} = model, profile) when is_integer(profile) and profile >= 0 do
    profile_matrix(model, model.duration_matrices, profile, &elem(&1, 2))
  end

  defp profile_matrix(model, matrices, profile, override_of) do
    with {:ok, %{matrix: matrix, override_row: override_row}} <- profile_at(model, profile),
         {:ok, base} <- matrix_at(matrices, matrix, profile) do
      {:ok, base |> Matrix.to_lists() |> with_override_row(override_row, override_of)}
    end
  end

  defp profile_at(%__MODULE__{profiles: []}, profile), do: {:ok, %{matrix: profile, override_row: nil}}

  defp profile_at(%__MODULE__{profiles: profiles}, profile) do
    profiles
    |> Enum.fetch(profile)
    |> found_or("Model has #{length(profiles)} profiles, so no profile #{profile}")
  end

  defp matrix_at(matrices, matrix, profile) do
    matrices
    |> Enum.fetch(matrix)
    |> found_or("Profile #{profile} reads matrix #{matrix}, but the model has #{length(matrices)}")
  end

  defp found_or({:ok, _found} = found, _reason), do: found
  defp found_or(:error, reason), do: {:error, reason}

  defp with_override_row(rows, nil, _override_of), do: rows

  defp with_override_row(rows, {row, _distances, _durations} = override_row, override_of),
    do: List.replace_at(rows, row, Matrix.row_to_list(override_of.(override_row)))

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
  Locks clients to vehicle types. A locked client pays `price` whenever a vehicle type other than
  `vehicle_type` serves it, and nothing when its own does or when it is not served at all.

  `location` is a location index in matrix order (depots first, then clients), as for
  `set_penalties/2`. At most one lock per client. Defaults to no locks.

  ## Example

      model
      |> ExVrp.Model.set_vehicle_locks([%{location: 3, vehicle_type: 0, price: 5_000}])
  """
  @spec set_vehicle_locks(t(), [
          %{location: non_neg_integer(), vehicle_type: non_neg_integer(), price: non_neg_integer()}
        ]) ::
          t()
  def set_vehicle_locks(%__MODULE__{} = model, locks), do: %{model | vehicle_locks: locks}

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
      |> validate_duration_matrix_count(model)
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
      |> Breaks.validate(model)
      |> validate_matrix_dimensions(model)
      |> validate_matrix_diagonals(model)
      |> validate_profiles(model)
      |> validate_client_groups(model)
      |> validate_same_vehicle_groups(model)
      |> Shipment.validate(model)
      |> validate_penalties(model)
      |> validate_vehicle_locks(model)
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

  defp validate_duration_matrix_count(errors, %{distance_matrices: dist, duration_matrices: dur}),
    do: duration_matrix_count_errors(length(dist), length(dur)) ++ errors

  defp duration_matrix_count_errors(count, count), do: []

  defp duration_matrix_count_errors(distance_count, duration_count) do
    [
      "Expected one duration matrix per distance matrix (#{distance_count}), got #{duration_count} — see set_duration_matrices/2"
    ]
  end

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

  defp validate_vehicle_locks(errors, %{vehicle_locks: []}), do: errors

  defp validate_vehicle_locks(errors, model) do
    num_depots = length(model.depots)
    num_locations = num_locations(model)
    num_vehicle_types = length(model.vehicle_types)

    errors
    |> validate_lock_entries(model.vehicle_locks, num_depots, num_locations, num_vehicle_types)
    |> validate_lock_duplicates(model.vehicle_locks)
  end

  defp validate_lock_entries(errors, locks, num_depots, num_locations, num_vehicle_types) do
    new_errors = Enum.flat_map(locks, &lock_errors(&1, num_depots, num_locations, num_vehicle_types))
    new_errors ++ errors
  end

  defp lock_errors(%{location: loc, vehicle_type: vt, price: price}, num_depots, num_locations, num_vehicle_types) do
    location_lock_errors(loc, num_depots, num_locations) ++
      vehicle_type_lock_errors(loc, vt, num_vehicle_types) ++ price_lock_errors(loc, price)
  end

  defp lock_errors(malformed, _num_depots, _num_locations, _num_vehicle_types) do
    ["vehicle lock is not a %{location:, vehicle_type:, price:} map: #{inspect(malformed)}"]
  end

  defp location_lock_errors(loc, num_depots, num_locations) do
    if non_neg_integer?(loc) do
      Enum.filter(
        [
          loc < num_depots && "vehicle lock on location #{loc}: depots cannot be locked",
          loc >= num_locations && "vehicle lock on location #{loc}: no such location"
        ],
        &is_binary/1
      )
    else
      ["vehicle lock has a non-negative-integer location, got: #{inspect(loc)}"]
    end
  end

  defp vehicle_type_lock_errors(loc, vt, num_vehicle_types) do
    cond do
      not non_neg_integer?(vt) ->
        ["vehicle lock on location #{inspect(loc)} has a non-negative-integer vehicle_type, got: #{inspect(vt)}"]

      vt >= num_vehicle_types ->
        ["vehicle lock on location #{inspect(loc)}: vehicle type #{vt} does not exist"]

      true ->
        []
    end
  end

  defp price_lock_errors(loc, price) do
    if non_neg_integer?(price) do
      []
    else
      ["vehicle lock on location #{inspect(loc)}: price must be a non-negative integer"]
    end
  end

  defp validate_lock_duplicates(errors, locks) do
    duplicate_errors =
      locks
      |> Enum.filter(&match?(%{location: _location}, &1))
      |> Enum.frequencies_by(& &1.location)
      |> Enum.filter(fn {_loc, count} -> count > 1 end)
      |> Enum.map(fn {loc, _count} -> "location #{inspect(loc)} has more than one lock" end)

    duplicate_errors ++ errors
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

  defp num_profiles(%{profiles: [_first | _rest] = profiles}), do: length(profiles)

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
    if Enum.all?(matrices, &Matrix.square?(&1, expected_size)) do
      errors
    else
      ["#{name} matrix dimensions don't match number of locations" | errors]
    end
  end

  defp validate_matrix_diagonals(errors, %{distance_matrices: [], duration_matrices: []}) do
    errors
  end

  defp validate_matrix_diagonals(errors, model) do
    %{distance_matrices: dist, duration_matrices: dur} = model
    size = num_locations(model)

    errors
    |> check_diagonal(dist, size, "Distance")
    |> check_diagonal(dur, size, "Duration")
  end

  defp check_diagonal(errors, matrices, size, name) do
    if matrices |> Enum.filter(&Matrix.square?(&1, size)) |> Enum.all?(&Matrix.zero_diagonal?/1) do
      errors
    else
      ["#{name} matrix diagonal must be zero" | errors]
    end
  end

  defp validate_profiles(errors, %{profiles: []}), do: errors

  defp validate_profiles(errors, model) do
    num_matrices = min(length(model.distance_matrices), length(model.duration_matrices))
    size = num_locations(model)

    model.profiles
    |> Enum.with_index()
    |> Enum.flat_map(fn {profile, index} -> profile_errors(profile, index, num_matrices, size) end)
    |> Enum.reverse(errors)
  end

  defp profile_errors(%{matrix: matrix, override_row: override_row}, index, num_matrices, size) do
    matrix_errors(matrix, index, num_matrices) ++ override_row_errors(override_row, index, size)
  end

  defp profile_errors(malformed, index, _num_matrices, _size) do
    ["Profile #{index} is not a %{matrix:, override_row:} map: #{inspect(malformed)}"]
  end

  defp matrix_errors(matrix, _index, num_matrices) when is_integer(matrix) and matrix in 0..(num_matrices - 1)//1,
    do: []

  defp matrix_errors(matrix, index, num_matrices) do
    ["Profile #{index} names matrix #{inspect(matrix)}, but there are #{num_matrices}"]
  end

  defp override_row_errors(nil, _index, _size), do: []

  defp override_row_errors({row, distances, durations}, index, size) when is_integer(row) and row in 0..(size - 1)//1 do
    Enum.flat_map([{"distance", distances}, {"duration", durations}], &override_cell_errors(&1, row, index, size))
  end

  defp override_row_errors(override_row, index, _size) do
    [
      "Profile #{index} override_row must be nil or {row, distances, durations} on a location, got: " <>
        inspect(override_row, limit: 3)
    ]
  end

  defp override_cell_errors({name, cells}, row, index, size) do
    if Matrix.row?(cells, size),
      do: diagonal_cell_errors(name, Matrix.row_at(cells, row), index),
      else: ["Profile #{index} override #{name} row must hold one cell per location"]
  end

  defp diagonal_cell_errors(_name, 0, _index), do: []

  defp diagonal_cell_errors(name, _cell, index),
    do: ["Profile #{index} override #{name} row must be zero on the diagonal"]

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
        model
        |> Breaks.append_pool()
        |> ExVrp.Native.create_problem_data()

      {:error, _reason} = error ->
        error
    end
  end
end

defmodule ExVrp.Read do
  @moduledoc """
  Reads VRPLIB format instance files.

  A VRPLIB file contains a vehicle routing problem instance in a standardized
  text format. This module provides functions to parse these files and create
  an `ExVrp.Model` that can be solved.

  ## Rounding Functions

  When reading instances, you can specify a rounding function to apply to
  floating-point values:

  - `:none` - No rounding (default)
  - `:round` - Round to nearest integer
  - `:trunc` - Truncate to integer
  - `:dimacs` - Scale by 10 and truncate (for DIMACS benchmarks)
  - `:exact` - Scale by 1000 and round (for high precision)

  ## Example

      # Read a VRPLIB instance
      model = ExVrp.Read.read("instances/E-n22-k4.vrp")

      # With rounding
      model = ExVrp.Read.read("instances/RC208.vrp", round_func: :round)

  """

  alias ExVrp.Model

  @type round_func :: :none | :round | :trunc | :dimacs | :exact | (float() -> integer())

  # Maximum value for integers (matches PyVRP's MAX_VALUE)
  @max_value 4_611_686_018_427_387_903

  @doc """
  Reads a VRPLIB format file and returns an ExVrp.Model.

  ## Options

  - `:round_func` - Rounding function to apply to values (default: `:none`)

  ## Examples

      model = ExVrp.Read.read("instances/OkSmall.txt")
      model = ExVrp.Read.read("instances/E-n22-k4.vrp", round_func: :dimacs)

  """
  @spec read(String.t() | Path.t(), keyword()) :: Model.t()
  def read(path, opts \\ []) do
    round_func = Keyword.get(opts, :round_func, :none)
    round_fn = get_round_func(round_func)

    path
    |> File.read!()
    |> parse_instance()
    |> build_model(round_fn)
  end

  # Get the rounding function
  defp get_round_func(:none), do: fn x -> x end
  defp get_round_func(:round), do: &round/1
  defp get_round_func(:trunc), do: &trunc/1
  defp get_round_func(:dimacs), do: fn x -> trunc(10 * x) end
  defp get_round_func(:exact), do: fn x -> round(1000 * x) end
  defp get_round_func(func) when is_function(func, 1), do: func
  defp get_round_func(other), do: raise(ArgumentError, "Unknown round_func: #{inspect(other)}")

  # Parse a VRPLIB format file into a map of sections
  defp parse_instance(content) do
    lines =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    parse_lines(lines, %{})
  end

  defp parse_lines([], acc), do: acc

  defp parse_lines([line | rest], acc) do
    cond do
      # Key-value pairs (e.g., "NAME : OkSmall")
      String.contains?(line, ":") and not String.ends_with?(line, "_SECTION") ->
        [key, value] = String.split(line, ":", parts: 2)
        key = key |> String.trim() |> String.downcase() |> String.to_atom()
        value = parse_value(String.trim(value))
        parse_lines(rest, Map.put(acc, key, value))

      # Section headers (e.g., "NODE_COORD_SECTION")
      String.ends_with?(line, "_SECTION") ->
        section_name =
          line
          |> String.trim_trailing("_SECTION")
          |> String.downcase()
          |> String.to_atom()

        {section_data, remaining} = parse_section(rest, section_name)
        parse_lines(remaining, Map.put(acc, section_name, section_data))

      # EOF marker
      String.upcase(line) == "EOF" ->
        acc

      # Unknown line - skip
      true ->
        parse_lines(rest, acc)
    end
  end

  # Parse a value (number or string)
  defp parse_value(value) do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end
    end
  end

  # Parse a section until we hit a new section or EOF
  defp parse_section(lines, section_name) do
    {section_lines, remaining} =
      Enum.split_while(lines, fn line ->
        not (String.ends_with?(line, "_SECTION") or String.upcase(line) == "EOF")
      end)

    data = parse_section_data(section_name, section_lines)
    {data, remaining}
  end

  # Parse section data based on section type
  defp parse_section_data(:edge_weight, lines) do
    # Parse matrix data (can be multi-row)
    flat =
      Enum.flat_map(lines, fn line ->
        line
        |> String.split()
        |> Enum.map(&parse_number/1)
      end)

    size = trunc(:math.sqrt(length(flat)))

    if size * size == length(flat) do
      Enum.chunk_every(flat, size)
    else
      # Handle non-square (triangular, etc.) - for now assume square
      [flat]
    end
  end

  defp parse_section_data(:node_coord, lines) do
    Enum.map(lines, fn line ->
      [idx | coords] = String.split(line)
      {parse_number(idx), Enum.map(coords, &parse_number/1)}
    end)
  end

  defp parse_section_data(:depot, lines) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_number/1)
    |> Enum.filter(&(&1 > 0))
  end

  defp parse_section_data(section, lines)
       when section in [:demand, :service_time, :prize, :release_time, :linehaul, :backhaul] do
    Enum.map(lines, fn line ->
      [idx | values] = String.split(line)
      {parse_number(idx), Enum.map(values, &parse_number/1)}
    end)
  end

  defp parse_section_data(:time_window, lines) do
    Enum.map(lines, fn line ->
      [idx, early, late] = String.split(line)
      {parse_number(idx), {parse_number(early), parse_number(late)}}
    end)
  end

  defp parse_section_data(:vehicles_depot, lines) do
    Enum.map(lines, fn line ->
      parts = String.split(line)
      vehicle_idx = parse_number(Enum.at(parts, 0))
      depot_idx = parse_number(Enum.at(parts, 1))
      {vehicle_idx, depot_idx}
    end)
  end

  defp parse_section_data(:vehicles_allowed_clients, lines) do
    Enum.map(lines, fn line ->
      [vehicle_idx | clients] = line |> String.split() |> Enum.map(&parse_number/1)
      {vehicle_idx, clients}
    end)
  end

  defp parse_section_data(:vehicles_reload_depot, lines) do
    Enum.map(lines, fn line ->
      parts = line |> String.split() |> Enum.map(&parse_number/1)
      vehicle_idx = hd(parts)
      depots = tl(parts)
      {vehicle_idx, depots}
    end)
  end

  defp parse_section_data(:mutually_exclusive_group, lines) do
    Enum.map(lines, fn line ->
      [_group_id | clients] = line |> String.split() |> Enum.map(&parse_number/1)
      clients
    end)
  end

  defp parse_section_data(_section, lines) do
    # Default: return list of parsed lines
    Enum.map(lines, fn line ->
      parts = String.split(line)
      Enum.map(parts, &parse_number/1)
    end)
  end

  defp parse_number(str) do
    str = String.trim(str)

    case Integer.parse(str) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(str) do
          {float, ""} -> float
          _ -> str
        end
    end
  end

  # Build an ExVrp.Model from parsed instance data
  defp build_model(instance, round_fn) do
    dimension = Map.get(instance, :dimension, 0)
    num_depots = length(Map.get(instance, :depot, [1]))
    num_clients = dimension - num_depots

    # Get coordinates
    coords = build_coords(instance, round_fn)

    # Get depot indices (1-based in file, we use 0-based internally)
    depot_indices = instance |> Map.get(:depot, [1]) |> Enum.map(&(&1 - 1))

    # Build distance/duration matrix
    {distances, durations} = build_matrices(instance, coords, dimension, round_fn)

    # Build depots
    model =
      Enum.reduce(depot_indices, Model.new(), fn depot_idx, model ->
        {x, y} = Enum.at(coords, depot_idx)
        Model.add_depot(model, x: x, y: y)
      end)

    # Get vehicle info
    num_vehicles = Map.get(instance, :vehicles, num_clients)
    capacity = get_capacity(instance, num_vehicles, round_fn)
    vehicles_depots = get_vehicles_depots(instance, num_vehicles, depot_indices)
    max_distances = get_max_distances(instance, num_vehicles, round_fn)
    shift_durations = get_shift_durations(instance, num_vehicles, round_fn)
    fixed_costs = get_fixed_costs(instance, num_vehicles, round_fn)
    unit_distance_costs = get_unit_distance_costs(instance, num_vehicles)
    reload_depots = get_reload_depots(instance, num_vehicles)
    max_reloads = get_max_reloads(instance, num_vehicles)
    allowed_clients = get_allowed_clients(instance, num_vehicles, num_depots, dimension)

    # Get time windows from depot for vehicles
    time_windows = build_time_windows(instance, round_fn)

    # Get mutually exclusive groups
    groups = Map.get(instance, :mutually_exclusive_group, [])
    # Filter out groups with less than 2 members
    groups = Enum.filter(groups, fn g -> length(g) > 1 end)

    # Build client index -> group mapping
    client_to_group =
      groups
      |> Enum.with_index()
      |> Enum.flat_map(fn {members, group_idx} ->
        Enum.map(members, fn client_idx -> {client_idx, group_idx} end)
      end)
      |> Map.new()

    # Add client groups to model
    {model, _group_indices} =
      Enum.reduce(groups, {model, []}, fn _group, {m, indices} ->
        {new_model, idx} = Model.add_client_group(m, required: false)
        {new_model, indices ++ [idx]}
      end)

    # Build clients
    demands = build_demands(instance, round_fn)
    backhauls = build_backhauls(instance, round_fn)
    service_times = build_service_times(instance, dimension, round_fn)
    prizes = build_prizes(instance, round_fn)
    release_times = build_release_times(instance, round_fn)

    # Add clients (all locations except depots)
    client_indices =
      Enum.filter(0..(dimension - 1), fn idx -> idx not in depot_indices end)

    model =
      Enum.reduce(client_indices, model, fn loc_idx, model ->
        {x, y} = Enum.at(coords, loc_idx)
        demand = Map.get(demands, loc_idx, [0])
        backhaul = Map.get(backhauls, loc_idx, [0])
        service = Map.get(service_times, loc_idx, 0)
        {tw_early, tw_late} = Map.get(time_windows, loc_idx, {0, @max_value})
        prize = Map.get(prizes, loc_idx, 0)
        release = Map.get(release_times, loc_idx, 0)

        # Check if client is in a mutually exclusive group
        group_idx = Map.get(client_to_group, loc_idx)

        # A client is required if it has no prize and is not in a group
        required = prize == 0 and group_idx == nil

        Model.add_client(model,
          x: x,
          y: y,
          delivery: demand,
          pickup: backhaul,
          service_duration: service,
          tw_early: tw_early,
          tw_late: tw_late,
          release_time: release,
          prize: prize,
          required: required,
          group: group_idx
        )
      end)

    # Group vehicles by their attributes to create vehicle types
    vehicles_data =
      for veh <- 0..(num_vehicles - 1) do
        cap = Enum.at(capacity, veh)
        depot = Enum.at(vehicles_depots, veh)
        max_dist = Enum.at(max_distances, veh)
        shift_dur = Enum.at(shift_durations, veh)
        fixed_cost = Enum.at(fixed_costs, veh)
        unit_dist_cost = Enum.at(unit_distance_costs, veh)
        reload = Enum.at(reload_depots, veh)
        max_reload = Enum.at(max_reloads, veh)
        allowed = Enum.at(allowed_clients, veh)

        {veh, cap, depot, max_dist, shift_dur, fixed_cost, unit_dist_cost, reload, max_reload, allowed}
      end

    # Group by attributes (excluding vehicle index)
    type_groups =
      Enum.group_by(vehicles_data, fn {_veh, cap, depot, max_dist, shift_dur, fixed_cost, unit_dist_cost, reload,
                                       max_reload, allowed} ->
        {cap, depot, max_dist, shift_dur, fixed_cost, unit_dist_cost, reload, max_reload, allowed}
      end)

    # Get depot time windows for vehicle types
    depot_time_windows =
      Enum.map(depot_indices, fn depot_idx ->
        Map.get(time_windows, depot_idx, {0, @max_value})
      end)

    # Build vehicle types from groups (need to know profile mapping)
    {model, _profile_map} =
      Enum.reduce(type_groups, {model, %{}}, fn {{cap, depot, max_dist, shift_dur, fixed_cost, unit_dist_cost, reload,
                                                  _max_reload, allowed}, vehicles},
                                                {m, profile_map} ->
        num_available = length(vehicles)
        vehicle_indices = Enum.map(vehicles, fn {veh, _, _, _, _, _, _, _, _, _} -> veh end)
        name = Enum.join(vehicle_indices, ",")

        # Get or create profile for this allowed_clients set
        {profile, new_profile_map} =
          case Map.get(profile_map, allowed) do
            nil ->
              new_idx = map_size(profile_map)
              {new_idx, Map.put(profile_map, allowed, new_idx)}

            existing ->
              {existing, profile_map}
          end

        # Get depot time window
        {tw_early, tw_late} = Enum.at(depot_time_windows, depot, {0, @max_value})

        m =
          Model.add_vehicle_type(m,
            num_available: num_available,
            capacity: cap,
            start_depot: depot,
            end_depot: depot,
            fixed_cost: fixed_cost,
            tw_early: tw_early,
            tw_late: tw_late,
            shift_duration: shift_dur,
            max_distance: max_dist,
            unit_distance_cost: unit_dist_cost,
            profile: profile,
            reload_depots: reload,
            name: name
          )

        {m, new_profile_map}
      end)

    # Build distance/duration matrices
    # First, determine how many profiles we need based on allowed_clients variations
    unique_allowed =
      allowed_clients
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new()

    is_vrpb = Map.get(instance, :type, "") == "VRPB"
    all_clients = Enum.to_list(num_depots..(dimension - 1))

    matrix_context = %{
      distances: distances,
      durations: durations,
      demands: demands,
      backhauls: backhauls,
      num_depots: num_depots,
      dimension: dimension,
      all_clients: all_clients,
      is_vrpb: is_vrpb
    }

    {dist_matrices, dur_matrices} = build_profile_matrices(unique_allowed, matrix_context)

    model
    |> Model.set_distance_matrices(dist_matrices)
    |> Model.set_duration_matrices(dur_matrices)
  end

  defp build_profile_matrices(unique_allowed, ctx) when map_size(unique_allowed) == 0 do
    {[ctx.distances], [ctx.durations]}
  end

  defp build_profile_matrices(unique_allowed, ctx) do
    matrices =
      unique_allowed
      |> Enum.sort_by(fn {_, idx} -> idx end)
      |> Enum.map(fn {allowed, _idx} -> build_profile_matrix(allowed, ctx) end)

    {Enum.map(matrices, &elem(&1, 0)), Enum.map(matrices, &elem(&1, 1))}
  end

  defp build_profile_matrix(allowed, %{all_clients: all_clients, is_vrpb: false} = ctx) when allowed == all_clients do
    {ctx.distances, ctx.durations}
  end

  defp build_profile_matrix(allowed, ctx) do
    {d, u} = maybe_apply_vrpb(ctx)
    apply_allowed_clients_restrictions(d, u, allowed, ctx.dimension, ctx.num_depots)
  end

  defp maybe_apply_vrpb(%{is_vrpb: true} = ctx) do
    apply_vrpb_modifications(ctx.distances, ctx.durations, ctx.demands, ctx.backhauls, ctx.num_depots)
  end

  defp maybe_apply_vrpb(ctx), do: {ctx.distances, ctx.durations}

  # Build coordinate lookup
  defp build_coords(instance, round_fn) do
    case Map.get(instance, :node_coord) do
      nil ->
        dimension = Map.get(instance, :dimension, 0)
        List.duplicate({0, 0}, dimension)

      coords ->
        # Coords are {idx, [x, y]}
        coords
        |> Enum.sort_by(fn {idx, _} -> idx end)
        |> Enum.map(fn {_idx, [x, y]} -> {round_fn.(x), round_fn.(y)} end)
    end
  end

  # Build distance and duration matrices
  defp build_matrices(instance, coords, dimension, round_fn) do
    edge_weight_type =
      instance
      |> Map.get(:edge_weight_type, "EXPLICIT")
      |> to_string()
      |> String.upcase()

    distances = build_distance_matrix(edge_weight_type, instance, coords, dimension, round_fn)

    # Duration matrices typically equal distance matrices in VRPLIB
    {distances, distances}
  end

  defp build_distance_matrix("EXPLICIT", instance, _coords, dimension, round_fn) do
    instance
    |> Map.get(:edge_weight, [])
    |> parse_edge_weights(dimension)
    |> apply_rounding(round_fn)
  end

  defp build_distance_matrix("EUC_2D", _instance, coords, _dimension, round_fn) do
    for {x1, y1} <- coords do
      for {x2, y2} <- coords do
        euclidean_distance({x1, y1}, {x2, y2}, round_fn)
      end
    end
  end

  defp build_distance_matrix(other, _instance, _coords, _dimension, _round_fn) do
    raise ArgumentError, "Unsupported edge weight type: #{other}"
  end

  defp parse_edge_weights([[_ | _] | _] = matrix, _dimension), do: matrix
  defp parse_edge_weights(flat_list, dimension), do: Enum.chunk_every(flat_list, dimension)

  defp apply_rounding(matrix, round_fn) do
    Enum.map(matrix, fn row -> Enum.map(row, round_fn) end)
  end

  defp euclidean_distance({x1, y1}, {x2, y2}, round_fn) do
    dx = x2 - x1
    dy = y2 - y1
    round_fn.(:math.sqrt(dx * dx + dy * dy))
  end

  # Build time windows map
  defp build_time_windows(instance, round_fn) do
    case Map.get(instance, :time_window) do
      nil ->
        %{}

      windows ->
        Map.new(windows, fn {idx, {early, late}} ->
          {idx - 1, {round_fn.(early), round_fn.(late)}}
        end)
    end
  end

  # Build demands map (location_idx -> [demand values])
  defp build_demands(instance, round_fn) do
    demands = Map.get(instance, :demand) || Map.get(instance, :linehaul)

    case demands do
      nil ->
        %{}

      list ->
        Map.new(list, fn {idx, values} ->
          {idx - 1, Enum.map(values, round_fn)}
        end)
    end
  end

  # Build backhauls map
  defp build_backhauls(instance, round_fn) do
    case Map.get(instance, :backhaul) do
      nil ->
        %{}

      list ->
        Map.new(list, fn {idx, values} ->
          {idx - 1, Enum.map(values, round_fn)}
        end)
    end
  end

  # Build service times map
  defp build_service_times(instance, dimension, round_fn) do
    case Map.get(instance, :service_time) do
      nil ->
        %{}

      list when is_list(list) ->
        Map.new(list, fn {idx, [value | _]} ->
          {idx - 1, round_fn.(value)}
        end)

      value when is_number(value) ->
        # Uniform service time for all clients
        num_depots = length(Map.get(instance, :depot, [1]))

        Map.new(num_depots..(dimension - 1), fn idx ->
          {idx, round_fn.(value)}
        end)
    end
  end

  # Build prizes map
  defp build_prizes(instance, round_fn) do
    case Map.get(instance, :prize) do
      nil -> %{}
      list -> Map.new(list, fn {idx, [value | _]} -> {idx - 1, round_fn.(value)} end)
    end
  end

  # Build release times map
  defp build_release_times(instance, round_fn) do
    case Map.get(instance, :release_time) do
      nil -> %{}
      list -> Map.new(list, fn {idx, [value | _]} -> {idx - 1, round_fn.(value)} end)
    end
  end

  # Get capacity for each vehicle
  defp get_capacity(instance, num_vehicles, round_fn) do
    case Map.get(instance, :capacity) do
      nil ->
        List.duplicate([@max_value], num_vehicles)

      cap when is_number(cap) ->
        List.duplicate([round_fn.(cap)], num_vehicles)

      caps when is_list(caps) ->
        Enum.map(caps, fn c -> [round_fn.(c)] end)
    end
  end

  # Get depot for each vehicle
  defp get_vehicles_depots(instance, num_vehicles, depot_indices) do
    case Map.get(instance, :vehicles_depot) do
      nil ->
        # All vehicles at first depot
        first_depot = hd(depot_indices)
        List.duplicate(first_depot, num_vehicles)

      list ->
        list
        |> Enum.sort_by(fn {veh, _} -> veh end)
        |> Enum.map(fn {_veh, depot} -> depot - 1 end)
    end
  end

  # Get max distances for each vehicle
  defp get_max_distances(instance, num_vehicles, round_fn) do
    case Map.get(instance, :vehicles_max_distance) do
      nil -> List.duplicate(@max_value, num_vehicles)
      val when is_number(val) -> List.duplicate(round_fn.(val), num_vehicles)
      list -> Enum.map(list, round_fn)
    end
  end

  # Get shift durations for each vehicle
  defp get_shift_durations(instance, num_vehicles, round_fn) do
    case Map.get(instance, :vehicles_max_duration) do
      nil -> List.duplicate(@max_value, num_vehicles)
      val when is_number(val) -> List.duplicate(round_fn.(val), num_vehicles)
      list -> Enum.map(list, round_fn)
    end
  end

  # Get fixed costs for each vehicle
  defp get_fixed_costs(instance, num_vehicles, round_fn) do
    case Map.get(instance, :vehicles_fixed_cost) do
      nil -> List.duplicate(0, num_vehicles)
      val when is_number(val) -> List.duplicate(round_fn.(val), num_vehicles)
      list -> Enum.map(list, round_fn)
    end
  end

  # Get unit distance costs for each vehicle
  defp get_unit_distance_costs(instance, num_vehicles) do
    # Note: unit distance costs are not rounded to prevent double scaling
    case Map.get(instance, :vehicles_unit_distance_cost) do
      nil -> List.duplicate(1, num_vehicles)
      val when is_number(val) -> List.duplicate(val, num_vehicles)
      list -> list
    end
  end

  # Get reload depots for each vehicle
  defp get_reload_depots(instance, num_vehicles) do
    case Map.get(instance, :vehicles_reload_depot) do
      nil ->
        List.duplicate([], num_vehicles)

      list ->
        # Create a map of vehicle -> reload depots
        reload_map =
          Map.new(list, fn {veh, depots} ->
            # Convert to 0-indexed
            {veh - 1, Enum.map(depots, &(&1 - 1))}
          end)

        for veh <- 0..(num_vehicles - 1) do
          Map.get(reload_map, veh, [])
        end
    end
  end

  # Get max reloads for each vehicle
  defp get_max_reloads(instance, num_vehicles) do
    case Map.get(instance, :vehicles_max_reloads) do
      nil -> List.duplicate(:infinity, num_vehicles)
      val when is_number(val) -> List.duplicate(val, num_vehicles)
      list -> list
    end
  end

  # Get allowed clients for each vehicle
  defp get_allowed_clients(instance, num_vehicles, num_depots, dimension) do
    all_clients = Enum.to_list(num_depots..(dimension - 1))

    case Map.get(instance, :vehicles_allowed_clients) do
      nil ->
        List.duplicate(all_clients, num_vehicles)

      list ->
        # Create a map of vehicle -> allowed clients
        allowed_map =
          Map.new(list, fn {veh, clients} ->
            # Convert to 0-indexed
            {veh - 1, Enum.map(clients, &(&1 - 1))}
          end)

        for veh <- 0..(num_vehicles - 1) do
          Map.get(allowed_map, veh, all_clients)
        end
    end
  end

  # Apply VRPB modifications to matrices (linehaul before backhaul constraint)
  defp apply_vrpb_modifications(distances, durations, demands, backhauls, _num_depots) do
    # Identify linehaul and backhaul clients
    linehaul_clients =
      demands
      |> Enum.filter(fn {_idx, vals} -> Enum.any?(vals, &(&1 > 0)) end)
      |> MapSet.new(fn {idx, _} -> idx end)

    backhaul_clients =
      backhauls
      |> Enum.filter(fn {_idx, vals} -> Enum.any?(vals, &(&1 > 0)) end)
      |> MapSet.new(fn {idx, _} -> idx end)

    # Set MAX_VALUE for:
    # - depot (0) to backhaul clients
    # - backhaul to linehaul clients
    {modify_matrix(distances, linehaul_clients, backhaul_clients),
     modify_matrix(durations, linehaul_clients, backhaul_clients)}
  end

  defp modify_matrix(matrix, linehaul_clients, backhaul_clients) do
    matrix
    |> Enum.with_index()
    |> Enum.map(&modify_row(&1, linehaul_clients, backhaul_clients))
  end

  defp modify_row({row, from_idx}, linehaul, backhaul) do
    row
    |> Enum.with_index()
    |> Enum.map(&modify_cell(&1, from_idx, linehaul, backhaul))
  end

  defp modify_cell({val, to_idx}, 0, _linehaul, backhaul) do
    if MapSet.member?(backhaul, to_idx), do: @max_value, else: val
  end

  defp modify_cell({val, to_idx}, from_idx, linehaul, backhaul) do
    if MapSet.member?(backhaul, from_idx) and MapSet.member?(linehaul, to_idx) do
      @max_value
    else
      val
    end
  end

  defp apply_allowed_clients_restrictions(distances, durations, allowed, _dim, num_depots) do
    allowed_set = MapSet.new(Enum.to_list(0..(num_depots - 1)) ++ allowed)

    {restrict_matrix(distances, allowed_set), restrict_matrix(durations, allowed_set)}
  end

  defp restrict_matrix(matrix, allowed_set) do
    matrix
    |> Enum.with_index()
    |> Enum.map(&restrict_row(&1, allowed_set))
  end

  defp restrict_row({row, from_idx}, allowed_set) do
    row
    |> Enum.with_index()
    |> Enum.map(&restrict_cell(&1, from_idx, allowed_set))
  end

  defp restrict_cell({_val, idx}, idx, _allowed), do: 0

  defp restrict_cell({val, to_idx}, from_idx, allowed) do
    if MapSet.member?(allowed, from_idx) and MapSet.member?(allowed, to_idx) do
      val
    else
      @max_value
    end
  end
end

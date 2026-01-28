defmodule ExVrp.Neighbourhood do
  @moduledoc """
  Computes granular neighbourhood for local search.

  Uses Nx for efficient tensor operations, directly porting PyVRP's
  compute_neighbours algorithm from pyvrp/search/neighbourhood.py.

  ## Example

      # Get neighbours for a problem
      {:ok, problem_data} = ExVrp.Native.create_problem_data(model)
      params = ExVrp.NeighbourhoodParams.new(num_neighbours: 40)
      neighbours = ExVrp.Neighbourhood.compute_neighbours(problem_data, params)

      # neighbours is a list of lists:
      # - neighbours[0..num_depots-1] are empty (depots have no neighbours)
      # - neighbours[i] for clients contains the k nearest client indices

  """

  alias ExVrp.Native
  alias ExVrp.NeighbourhoodParams

  @doc """
  Computes neighbours for each location.

  Returns list of lists: neighbours[location] = [neighbour_indices...]
  Depots get empty lists.

  ## Parameters

  - `problem_data` - Reference to ProblemData resource
  - `params` - NeighbourhoodParams configuration

  ## Returns

  A list of lists where:
  - The first `num_depots` entries are empty lists
  - Each client entry contains the indices of its k nearest neighbours
  """
  @spec compute_neighbours(reference(), NeighbourhoodParams.t()) :: [[integer()]]
  def compute_neighbours(problem_data, params \\ %NeighbourhoodParams{})

  def compute_neighbours(problem_data, %NeighbourhoodParams{} = params) do
    # Get problem dimensions
    num_locs = Native.problem_data_num_locations(problem_data)
    num_depots = Native.problem_data_num_depots(problem_data)
    num_clients = Native.problem_data_num_clients(problem_data)

    # Compute proximity matrix using Nx tensors
    proximity = compute_proximity(problem_data, params, num_locs, num_depots)

    # Optionally symmetrize proximity: proximity = min(proximity, proximity.T)
    proximity =
      if params.symmetric_proximity do
        Nx.min(proximity, Nx.transpose(proximity))
      else
        proximity
      end

    # Handle mutually exclusive groups
    proximity = handle_mutually_exclusive(proximity, problem_data)

    # Set diagonal to infinity (cannot be in own neighbourhood)
    proximity = set_diagonal(proximity, num_locs, :infinity)

    # Set depot rows/cols to infinity (depots have no neighbours, clients don't neighbour depots)
    proximity = set_depot_boundaries(proximity, num_depots, num_locs)

    # Extract top-k neighbours per client
    k = min(params.num_neighbours, num_clients - 1)

    neighbours = extract_top_k(proximity, num_depots, num_locs, k)

    # Optionally symmetrize neighbourhood structure
    if params.symmetric_neighbours do
      symmetrize_neighbours(neighbours, num_locs, num_depots)
    else
      neighbours
    end
  end

  # ---------------------------------------------------------------------------
  # Private Functions
  # ---------------------------------------------------------------------------

  defp compute_proximity(problem_data, params, num_locs, num_depots) do
    # Get client data
    clients = Native.problem_data_clients_nif(problem_data)

    # Build vectors for time windows, service, prizes
    # PyVRP: early, late, service, prize are vectors of size num_locations
    # with depots having 0 values and clients having their actual values
    {early, late, service, prize} = build_location_vectors(clients, num_locs, num_depots)

    # Get distance/duration matrices for all profiles
    num_profiles = Native.problem_data_num_profiles_nif(problem_data)

    distances =
      for profile <- 0..(num_profiles - 1) do
        problem_data
        |> Native.problem_data_distance_matrix_nif(profile)
        |> Nx.tensor(type: :f64)
      end

    durations =
      for profile <- 0..(num_profiles - 1) do
        problem_data
        |> Native.problem_data_duration_matrix_nif(profile)
        |> Nx.tensor(type: :f64)
      end

    # Get vehicle types for cost computation
    vehicle_types = Native.problem_data_vehicle_types_nif(problem_data)

    # Compute minimum edge costs across all vehicle types
    edge_costs = compute_min_edge_costs(distances, durations, vehicle_types)

    # Compute minimum duration across profiles (for wait time / time warp)
    min_duration = compute_min_duration(durations)

    # Compute wait time penalties: early[j] - min_duration[i,j] - service[i] - late[i]
    # This represents the minimum wait time when visiting j directly after i
    min_wait = compute_min_wait(early, min_duration, service, late)

    # Compute time warp penalties: early[i] + service[i] + min_duration[i,j] - late[j]
    # This represents the minimum time warp when visiting j directly after i
    min_tw = compute_min_time_warp(early, min_duration, service, late)

    # Assemble proximity matrix:
    # proximity = edge_costs - prizes + weight_wait * max(min_wait, 0) + weight_tw * max(min_tw, 0)
    edge_costs
    |> Nx.subtract(Nx.new_axis(prize, 0))
    |> Nx.add(Nx.multiply(params.weight_wait_time, Nx.max(min_wait, 0)))
    |> Nx.add(Nx.multiply(params.weight_time_warp, Nx.max(min_tw, 0)))
  end

  defp build_location_vectors(clients, num_locs, num_depots) do
    # Initialize with zeros for depots
    early = Nx.broadcast(0.0, {num_locs})
    late = Nx.broadcast(0.0, {num_locs})
    service = Nx.broadcast(0.0, {num_locs})
    prize = Nx.broadcast(0.0, {num_locs})

    # Build lists for client values
    client_early = Enum.map(clients, fn {tw_early, _, _, _} -> tw_early end)
    client_late = Enum.map(clients, fn {_, tw_late, _, _} -> tw_late end)
    client_service = Enum.map(clients, fn {_, _, svc, _} -> svc end)
    client_prize = Enum.map(clients, fn {_, _, _, prz} -> prz end)

    # Create client tensors
    client_early_t = Nx.tensor(client_early, type: :f64)
    client_late_t = Nx.tensor(client_late, type: :f64)
    client_service_t = Nx.tensor(client_service, type: :f64)
    client_prize_t = Nx.tensor(client_prize, type: :f64)

    # Put client values at indices [num_depots, num_locs)
    indices = Nx.tensor(Enum.to_list(num_depots..(num_locs - 1)))

    early = Nx.indexed_put(early, Nx.new_axis(indices, 1), client_early_t)
    late = Nx.indexed_put(late, Nx.new_axis(indices, 1), client_late_t)
    service = Nx.indexed_put(service, Nx.new_axis(indices, 1), client_service_t)
    prize = Nx.indexed_put(prize, Nx.new_axis(indices, 1), client_prize_t)

    {early, late, service, prize}
  end

  defp compute_min_edge_costs(distances, durations, vehicle_types) do
    # Get unique edge cost combinations: {unit_dist, unit_dur, profile}
    unique_costs = Enum.uniq(vehicle_types)

    # Compute edge costs for first combination
    [{unit_dist, unit_dur, profile} | rest] = unique_costs

    initial_costs =
      Nx.add(
        Nx.multiply(unit_dist, Enum.at(distances, profile)),
        Nx.multiply(unit_dur, Enum.at(durations, profile))
      )

    # Take minimum across all vehicle type combinations
    Enum.reduce(rest, initial_costs, fn {ud, ut, p}, acc ->
      costs =
        Nx.add(
          Nx.multiply(ud, Enum.at(distances, p)),
          Nx.multiply(ut, Enum.at(durations, p))
        )

      Nx.min(acc, costs)
    end)
  end

  defp compute_min_duration(durations) do
    # Element-wise minimum across all duration matrices
    [first | rest] = durations
    Enum.reduce(rest, first, &Nx.min/2)
  end

  defp compute_min_wait(early, min_duration, service, late) do
    # min_wait[i,j] = early[j] - min_duration[i,j] - service[i] - late[i]
    # Broadcasting: early[j] -> (1, n), others -> (n, 1) or (n, n)
    early_j = Nx.new_axis(early, 0)
    service_i = Nx.new_axis(service, 1)
    late_i = Nx.new_axis(late, 1)

    early_j
    |> Nx.subtract(min_duration)
    |> Nx.subtract(service_i)
    |> Nx.subtract(late_i)
  end

  defp compute_min_time_warp(early, min_duration, service, late) do
    # min_tw[i,j] = early[i] + service[i] + min_duration[i,j] - late[j]
    # Broadcasting: late[j] -> (1, n), others -> (n, 1) or (n, n)
    early_i = Nx.new_axis(early, 1)
    service_i = Nx.new_axis(service, 1)
    late_j = Nx.new_axis(late, 0)

    early_i
    |> Nx.add(service_i)
    |> Nx.add(min_duration)
    |> Nx.subtract(late_j)
  end

  defp handle_mutually_exclusive(proximity, problem_data) do
    groups = Native.problem_data_groups_nif(problem_data)

    Enum.reduce(groups, proximity, fn {clients, mutually_exclusive}, acc ->
      if mutually_exclusive and length(clients) > 1 do
        # Clients in mutually exclusive groups cannot neighbour each other.
        # Use max float (not infinity) to ensure these clients are ordered
        # before the depots.
        max_float = :math.pow(2, 1023)
        set_group_proximity(acc, clients, max_float)
      else
        acc
      end
    end)
  end

  defp set_group_proximity(proximity, clients, value) do
    for i <- clients, j <- clients, i != j, reduce: proximity do
      acc -> Nx.indexed_put(acc, Nx.tensor([[i, j]]), Nx.tensor([value]))
    end
  end

  defp set_diagonal(proximity, num_locs, :infinity) do
    # Set diagonal to infinity
    inf = Nx.Constants.infinity()
    diag_indices = Nx.stack([Nx.iota({num_locs}), Nx.iota({num_locs})], axis: 1)
    diag_values = Nx.broadcast(inf, {num_locs})
    Nx.indexed_put(proximity, diag_indices, diag_values)
  end

  defp set_depot_boundaries(proximity, num_depots, num_locs) do
    inf = Nx.Constants.infinity()

    # Set depot rows to infinity (depots have no neighbours)
    # proximity[:num_depots, :] = inf
    depot_row_indices =
      for i <- 0..(num_depots - 1), j <- 0..(num_locs - 1), do: [i, j]

    proximity =
      if depot_row_indices == [] do
        proximity
      else
        idx = Nx.tensor(depot_row_indices)
        vals = Nx.broadcast(inf, {length(depot_row_indices)})
        Nx.indexed_put(proximity, idx, vals)
      end

    # Set depot columns to infinity (clients don't neighbour depots)
    # proximity[:, :num_depots] = inf
    depot_col_indices =
      for i <- 0..(num_locs - 1), j <- 0..(num_depots - 1), do: [i, j]

    if depot_col_indices == [] do
      proximity
    else
      idx = Nx.tensor(depot_col_indices)
      vals = Nx.broadcast(inf, {length(depot_col_indices)})
      Nx.indexed_put(proximity, idx, vals)
    end
  end

  defp extract_top_k(_proximity, num_depots, _num_locs, k) when k <= 0 do
    for _ <- 0..(num_depots - 1), do: []
  end

  defp extract_top_k(proximity, num_depots, num_locs, k) do
    depot_neighbours = for _ <- 0..(num_depots - 1), do: []

    client_neighbours =
      if num_depots < num_locs do
        for i <- num_depots..(num_locs - 1) do
          proximity
          |> extract_row_candidates(i, num_locs, num_depots)
          |> k_smallest(k)
          |> Enum.map(fn {_prox, idx} -> idx end)
        end
      else
        []
      end

    depot_neighbours ++ client_neighbours
  end

  defp extract_row_candidates(proximity, row_idx, num_locs, num_depots) do
    proximity
    |> Nx.slice([row_idx, 0], [1, num_locs])
    |> Nx.to_flat_list()
    |> Enum.with_index()
    |> Enum.filter(fn {_prox, j} -> j >= num_depots and j != row_idx end)
  end

  # Returns the k elements with smallest first-tuple values, sorted ascending.
  # Uses a bounded gb_set (balanced tree) for O(n log k) complexity.
  defp k_smallest(_candidates, k) when k <= 0, do: []

  defp k_smallest(candidates, k) do
    candidates
    |> Enum.reduce({:gb_sets.new(), 0}, &accumulate_smallest(&1, &2, k))
    |> elem(0)
    |> :gb_sets.to_list()
  end

  defp accumulate_smallest(candidate, {set, count}, k) when count < k do
    {:gb_sets.add(candidate, set), count + 1}
  end

  defp accumulate_smallest({prox, _} = candidate, {set, count}, _k) do
    {max_prox, _} = max_elem = :gb_sets.largest(set)

    if prox < max_prox do
      set = :gb_sets.delete(max_elem, set)
      {:gb_sets.add(candidate, set), count}
    else
      {set, count}
    end
  end

  defp symmetrize_neighbours(neighbours, num_locs, num_depots) do
    # Construct a symmetric adjacency matrix and return adjacent clients
    # adj[i, j] = true if j is in neighbours[i]

    # Start with false matrix
    adj = Nx.broadcast(0, {num_locs, num_locs})

    # Set adj[i, j] = 1 for each j in neighbours[i]
    adj =
      neighbours
      |> Enum.with_index()
      |> Enum.reduce(adj, fn {nbrs, i}, acc ->
        if nbrs == [] do
          acc
        else
          indices = for j <- nbrs, do: [i, j]
          idx = Nx.tensor(indices)
          vals = Nx.broadcast(1, {length(nbrs)})
          Nx.indexed_put(acc, idx, vals)
        end
      end)

    # Symmetrize: adj = adj | adj.T
    adj = Nx.max(adj, Nx.transpose(adj))

    # Convert back to neighbour lists
    for i <- 0..(num_locs - 1) do
      if i < num_depots do
        []
      else
        row = adj |> Nx.slice([i, 0], [1, num_locs]) |> Nx.to_flat_list()

        row
        |> Enum.with_index()
        |> Enum.filter(fn {val, _j} -> val == 1 end)
        |> Enum.map(fn {_val, j} -> j end)
      end
    end
  end
end

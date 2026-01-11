defmodule ExVrp.Native do
  @moduledoc """
  Low-level NIF bindings to PyVRP C++ core.

  This module provides direct bindings to the C++ implementation.
  Users should prefer the high-level API in `ExVrp` and `ExVrp.Model`.

  ## Implementation Status

  NIFs are implemented incrementally. Unimplemented functions raise
  `ExVrp.NotImplementedError` until the C++ bindings are complete.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    path = :filename.join(:code.priv_dir(:ex_vrp), ~c"ex_vrp_nif")

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, {:reload, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # ProblemData
  # ---------------------------------------------------------------------------

  @doc """
  Creates a ProblemData resource from a Model.
  """
  @spec create_problem_data(ExVrp.Model.t()) :: {:ok, reference()} | {:error, term()}
  def create_problem_data(_model), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Solver
  # ---------------------------------------------------------------------------

  @doc """
  Runs the solver on ProblemData.
  """
  @spec solve(reference(), keyword()) :: {:ok, reference()} | {:error, term()}
  def solve(_problem_data, _opts), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Solution - Implemented NIFs
  # ---------------------------------------------------------------------------

  @spec solution_distance(reference()) :: non_neg_integer()
  def solution_distance(_solution), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_duration(reference()) :: non_neg_integer()
  def solution_duration(_solution), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_routes(reference()) :: [[non_neg_integer()]]
  def solution_routes(_solution_ref), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_is_feasible(reference()) :: boolean()
  def solution_is_feasible(_solution_ref), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_is_complete(reference()) :: boolean()
  def solution_is_complete(_solution_ref), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_num_routes(reference()) :: non_neg_integer()
  def solution_num_routes(_solution_ref), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Solution - Not Yet Implemented
  # ---------------------------------------------------------------------------

  @spec solution_num_clients(reference()) :: non_neg_integer()
  def solution_num_clients(_solution_ref), do: :erlang.nif_error(:nif_not_loaded)

  @spec solution_unassigned(reference()) :: [non_neg_integer()]
  def solution_unassigned(_solution), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # CostEvaluator
  # ---------------------------------------------------------------------------

  @doc """
  Creates a CostEvaluator with penalty parameters.

  ## Options

  - `:load_penalties` - List of penalties for each load dimension (required)
  - `:tw_penalty` - Time window violation penalty (required)
  - `:dist_penalty` - Distance constraint violation penalty (required)
  """
  @spec create_cost_evaluator(keyword()) :: {:ok, reference()} | {:error, term()}
  def create_cost_evaluator(opts) when is_list(opts) do
    create_cost_evaluator_nif(Map.new(opts))
  end

  def create_cost_evaluator(opts) when is_map(opts) do
    create_cost_evaluator_nif(opts)
  end

  defp create_cost_evaluator_nif(_opts), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Computes the penalised cost of a solution (feasible or infeasible).
  """
  @spec solution_penalised_cost(reference(), reference()) :: non_neg_integer()
  def solution_penalised_cost(_solution, _cost_evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Computes the cost of a feasible solution. Returns max integer for infeasible.
  """
  @spec solution_cost(reference(), reference()) :: non_neg_integer() | :infinity
  def solution_cost(_solution, _cost_evaluator), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Random Solution
  # ---------------------------------------------------------------------------

  @doc """
  Creates a random solution for the given problem data.
  """
  @spec create_random_solution(reference(), keyword()) :: {:ok, reference()} | {:error, term()}
  def create_random_solution(problem_data, opts) when is_list(opts) do
    create_random_solution_nif(problem_data, Map.new(opts))
  end

  def create_random_solution(problem_data, opts) when is_map(opts) do
    create_random_solution_nif(problem_data, opts)
  end

  defp create_random_solution_nif(_problem_data, _opts), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Creates a solution from explicit routes.

  Routes is a list of lists of client IDs (integers).
  Client IDs are 1-indexed (depot is 0, clients start at 1).
  """
  @spec create_solution_from_routes(reference(), [[non_neg_integer()]]) ::
          {:ok, reference()} | {:error, term()}
  def create_solution_from_routes(problem_data, routes) do
    create_solution_from_routes_nif(problem_data, routes)
  end

  defp create_solution_from_routes_nif(_problem_data, _routes), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the number of load dimensions from ProblemData.
  """
  @spec problem_data_num_load_dims(reference()) :: non_neg_integer()
  def problem_data_num_load_dims(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the number of clients from ProblemData.
  """
  @spec problem_data_num_clients(reference()) :: non_neg_integer()
  def problem_data_num_clients(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the number of depots from ProblemData.
  """
  @spec problem_data_num_depots(reference()) :: non_neg_integer()
  def problem_data_num_depots(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the total number of locations (depots + clients) from ProblemData.
  """
  @spec problem_data_num_locations(reference()) :: non_neg_integer()
  def problem_data_num_locations(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the number of vehicle types from ProblemData.
  """
  @spec problem_data_num_vehicle_types(reference()) :: non_neg_integer()
  def problem_data_num_vehicle_types(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the total number of vehicles (sum of all vehicle types) from ProblemData.
  """
  @spec problem_data_num_vehicles(reference()) :: non_neg_integer()
  def problem_data_num_vehicles(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Checks if the problem data has time windows (any non-default TW on clients/depots).
  """
  @spec problem_data_has_time_windows_nif(reference()) :: boolean()
  def problem_data_has_time_windows_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the centroid (average x, y) of all client locations.
  """
  @spec problem_data_centroid_nif(reference()) :: {float(), float()}
  def problem_data_centroid_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the number of profiles (distance/duration matrix sets).
  """
  @spec problem_data_num_profiles_nif(reference()) :: non_neg_integer()
  def problem_data_num_profiles_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # ProblemData - Data Extraction for Neighbourhood Computation
  # ---------------------------------------------------------------------------

  @doc """
  Gets all client data for neighbourhood computation.
  Returns list of {tw_early, tw_late, service_duration, prize} tuples.
  """
  @spec problem_data_clients_nif(reference()) ::
          [{integer(), integer(), integer(), integer()}]
  def problem_data_clients_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the distance matrix for a specific profile.
  Returns a nested list of integers.
  """
  @spec problem_data_distance_matrix_nif(reference(), integer()) :: [[integer()]]
  def problem_data_distance_matrix_nif(_problem_data, _profile), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the duration matrix for a specific profile.
  Returns a nested list of integers.
  """
  @spec problem_data_duration_matrix_nif(reference(), integer()) :: [[integer()]]
  def problem_data_duration_matrix_nif(_problem_data, _profile), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets vehicle type cost info for neighbourhood computation.
  Returns list of {unit_distance_cost, unit_duration_cost, profile} tuples.
  """
  @spec problem_data_vehicle_types_nif(reference()) ::
          [{integer(), integer(), integer()}]
  def problem_data_vehicle_types_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets client groups for neighbourhood computation.
  Returns list of {[client_location_indices], mutually_exclusive} tuples.
  """
  @spec problem_data_groups_nif(reference()) :: [{[integer()], boolean()}]
  def problem_data_groups_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # LocalSearch
  # ---------------------------------------------------------------------------

  @doc """
  Performs local search on a solution.

  ## Options

  - `:exhaustive` - Whether to run exhaustive search (default: false)
  """
  @spec local_search(reference(), reference(), reference(), keyword()) ::
          {:ok, reference()} | {:error, term()}
  def local_search(solution, problem_data, cost_evaluator, opts \\ [])

  def local_search(solution, problem_data, cost_evaluator, opts) when is_list(opts) do
    local_search_nif(solution, problem_data, cost_evaluator, Map.new(opts))
  end

  def local_search(solution, problem_data, cost_evaluator, opts) when is_map(opts) do
    local_search_nif(solution, problem_data, cost_evaluator, opts)
  end

  defp local_search_nif(_solution, _problem_data, _cost_evaluator, _opts), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Configurable LocalSearch with specific operators
  # ---------------------------------------------------------------------------

  @doc """
  Performs local search with specific operators.

  ## Options

  - `:node_operators` - List of operator names (atoms):
    - `:exchange10` / `:relocate` - Relocate a single node
    - `:exchange11` / `:swap11` - Swap two nodes
    - `:exchange20` / `:relocate2` - Relocate two consecutive nodes
    - `:exchange21` / `:swap21` - Exchange 2 nodes for 1
    - `:exchange22` / `:swap22` - Exchange 2 nodes for 2
    - `:exchange30` / `:relocate3` - Relocate three consecutive nodes
    - `:exchange31` / `:swap31` - Exchange 3 nodes for 1
    - `:exchange32` / `:swap32` - Exchange 3 nodes for 2
    - `:exchange33` / `:swap33` - Exchange 3 nodes for 3
    - `:swap_tails` - Swap route tails
    - `:relocate_with_depot` - Relocate with depot reload (multi-trip)

  - `:route_operators` - List of route operator names:
    - `:swap_star` - SWAP* operator (Vidal et al.)
    - `:swap_routes` - Swap entire routes

  - `:exhaustive` - Whether to run exhaustive search (default: false)
  """
  @spec local_search_with_operators(reference(), reference(), reference(), keyword()) ::
          {:ok, reference()} | {:error, term()}
  def local_search_with_operators(solution, problem_data, cost_evaluator, opts \\ [])

  def local_search_with_operators(solution, problem_data, cost_evaluator, opts) when is_list(opts) do
    local_search_with_operators_nif(solution, problem_data, cost_evaluator, Map.new(opts))
  end

  def local_search_with_operators(solution, problem_data, cost_evaluator, opts) when is_map(opts) do
    local_search_with_operators_nif(solution, problem_data, cost_evaluator, opts)
  end

  defp local_search_with_operators_nif(_solution, _problem_data, _cost_evaluator, _opts),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Performs local search and returns operator statistics.

  Returns a map with:
  - `:local_search` - Map with `:num_moves`, `:num_improving`, `:num_updates`
  - `:operators` - List of maps with `:name`, `:num_evaluations`, `:num_applications`

  Same options as `local_search_with_operators/4`.
  """
  @spec local_search_stats(reference(), reference(), reference(), keyword()) :: map()
  def local_search_stats(solution, problem_data, cost_evaluator, opts \\ [])

  def local_search_stats(solution, problem_data, cost_evaluator, opts) when is_list(opts) do
    local_search_stats_nif(solution, problem_data, cost_evaluator, Map.new(opts))
  end

  def local_search_stats(solution, problem_data, cost_evaluator, opts) when is_map(opts) do
    local_search_stats_nif(solution, problem_data, cost_evaluator, opts)
  end

  defp local_search_stats_nif(_solution, _problem_data, _cost_evaluator, _opts), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Route - via Solution reference + route index
  # ---------------------------------------------------------------------------

  @doc """
  Gets the distance of a specific route in a solution.
  """
  @spec solution_route_distance(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_distance(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the duration of a specific route in a solution.
  """
  @spec solution_route_duration(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_duration(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the delivery load of a specific route in a solution.
  """
  @spec solution_route_delivery(reference(), non_neg_integer()) :: [non_neg_integer()]
  def solution_route_delivery(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the pickup load of a specific route in a solution.
  """
  @spec solution_route_pickup(reference(), non_neg_integer()) :: [non_neg_integer()]
  def solution_route_pickup(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Checks if a specific route in a solution is feasible.
  """
  @spec solution_route_is_feasible(reference(), non_neg_integer()) :: boolean()
  def solution_route_is_feasible(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets excess load of a specific route (per dimension).
  """
  @spec solution_route_excess_load(reference(), non_neg_integer()) :: [non_neg_integer()]
  def solution_route_excess_load(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets time warp of a specific route.
  """
  @spec solution_route_time_warp(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_time_warp(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets excess distance of a specific route.
  """
  @spec solution_route_excess_distance(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_excess_distance(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets overtime of a specific route.
  """
  @spec solution_route_overtime(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_overtime(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Checks if a specific route has excess load.
  """
  @spec solution_route_has_excess_load(reference(), non_neg_integer()) :: boolean()
  def solution_route_has_excess_load(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Checks if a specific route has time warp.
  """
  @spec solution_route_has_time_warp(reference(), non_neg_integer()) :: boolean()
  def solution_route_has_time_warp(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Checks if a specific route has excess distance.
  """
  @spec solution_route_has_excess_distance(reference(), non_neg_integer()) :: boolean()
  def solution_route_has_excess_distance(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the vehicle type of a specific route.
  """
  @spec solution_route_vehicle_type(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_vehicle_type(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the start depot of a specific route.
  """
  @spec solution_route_start_depot(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_start_depot(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the end depot of a specific route.
  """
  @spec solution_route_end_depot(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_end_depot(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the number of trips in a specific route.
  """
  @spec solution_route_num_trips(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_num_trips(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the centroid of a specific route as {x, y}.
  """
  @spec solution_route_centroid(reference(), non_neg_integer()) :: {float(), float()}
  def solution_route_centroid(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the start time of a specific route.
  """
  @spec solution_route_start_time(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_start_time(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the end time of a specific route.
  """
  @spec solution_route_end_time(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_end_time(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the slack time of a specific route.
  """
  @spec solution_route_slack(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_slack(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the service duration of a specific route.
  """
  @spec solution_route_service_duration(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_service_duration(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the travel duration of a specific route.
  """
  @spec solution_route_travel_duration(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_travel_duration(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the wait duration of a specific route.
  """
  @spec solution_route_wait_duration(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_wait_duration(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the distance cost of a specific route.
  """
  @spec solution_route_distance_cost(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_distance_cost(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the duration cost of a specific route.
  """
  @spec solution_route_duration_cost(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_duration_cost(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the prizes collected on a specific route.
  """
  @spec solution_route_prizes(reference(), non_neg_integer()) :: non_neg_integer()
  def solution_route_prizes(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Gets the visits (client indices) of a specific route.
  """
  @spec solution_route_visits(reference(), non_neg_integer()) :: [non_neg_integer()]
  def solution_route_visits(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns the schedule of a route as a list of ScheduledVisit tuples.

  Each tuple contains: {location, trip, start_service, end_service, wait_duration, time_warp}
  """
  @spec solution_route_schedule(reference(), non_neg_integer()) ::
          [
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
             non_neg_integer()}
          ]
  def solution_route_schedule(_solution, _route_idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns the total fixed vehicle cost of the solution.
  """
  @spec solution_fixed_vehicle_cost(reference()) :: non_neg_integer()
  def solution_fixed_vehicle_cost(_solution), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Route - Legacy API (delegates to solution_route_* with stored reference)
  # ---------------------------------------------------------------------------

  @spec route_distance(ExVrp.Route.t()) :: non_neg_integer()
  def route_distance(%ExVrp.Route{} = _route) do
    raise ExVrp.NotImplementedError,
          "route_distance/1 - use ExVrp.Native.solution_route_distance/2 instead"
  end

  @spec route_duration(ExVrp.Route.t()) :: non_neg_integer()
  def route_duration(%ExVrp.Route{} = _route) do
    raise ExVrp.NotImplementedError,
          "route_duration/1 - use ExVrp.Native.solution_route_duration/2 instead"
  end

  @spec route_delivery(ExVrp.Route.t()) :: [non_neg_integer()]
  def route_delivery(%ExVrp.Route{} = _route) do
    raise ExVrp.NotImplementedError,
          "route_delivery/1 - use ExVrp.Native.solution_route_delivery/2 instead"
  end

  @spec route_pickup(ExVrp.Route.t()) :: [non_neg_integer()]
  def route_pickup(%ExVrp.Route{} = _route) do
    raise ExVrp.NotImplementedError,
          "route_pickup/1 - use ExVrp.Native.solution_route_pickup/2 instead"
  end

  @spec route_is_feasible(ExVrp.Route.t()) :: boolean()
  def route_is_feasible(%ExVrp.Route{} = _route) do
    raise ExVrp.NotImplementedError,
          "route_is_feasible/1 - use ExVrp.Native.solution_route_is_feasible/2 instead"
  end

  # ---------------------------------------------------------------------------
  # search::Route NIFs (low-level search route manipulation)
  # ---------------------------------------------------------------------------

  @doc "Creates a new search route."
  def create_search_route_nif(_problem_data, _idx, _vehicle_type), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route index."
  def search_route_idx_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route vehicle type."
  def search_route_vehicle_type_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the number of clients in the route."
  def search_route_num_clients_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the number of depots in the route."
  def search_route_num_depots_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the number of trips in the route."
  def search_route_num_trips_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the max trips allowed for the route."
  def search_route_max_trips_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route size (total nodes including depots)."
  def search_route_size_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the route is empty."
  def search_route_empty_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the route is feasible."
  def search_route_is_feasible_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the route has excess load."
  def search_route_has_excess_load_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the route has excess distance."
  def search_route_has_excess_distance_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the route has time warp."
  def search_route_has_time_warp_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route distance."
  def search_route_distance_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route duration."
  def search_route_duration_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route time warp."
  def search_route_time_warp_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route overtime."
  def search_route_overtime_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route excess distance."
  def search_route_excess_distance_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route load (as list)."
  def search_route_load_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route excess load (as list)."
  def search_route_excess_load_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route capacity (as list)."
  def search_route_capacity_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route start depot."
  def search_route_start_depot_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route end depot."
  def search_route_end_depot_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the fixed vehicle cost."
  def search_route_fixed_vehicle_cost_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the distance cost."
  def search_route_distance_cost_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the duration cost."
  def search_route_duration_cost_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the unit distance cost."
  def search_route_unit_distance_cost_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the unit duration cost."
  def search_route_unit_duration_cost_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route centroid."
  def search_route_centroid_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route profile."
  def search_route_profile_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets a node at the given index."
  def search_route_get_node_nif(_route, _idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Appends a node to the route."
  def search_route_append_nif(_route, _node), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Inserts a node at the given index."
  def search_route_insert_nif(_route, _idx, _node), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Removes the node at the given index."
  def search_route_remove_nif(_route, _idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Clears the route."
  def search_route_clear_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Updates the route (recomputes statistics)."
  def search_route_update_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Swaps two nodes."
  def search_route_swap_nif(_node1, _node2), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if two routes overlap with the given tolerance (0.0 to 1.0)."
  def search_route_overlaps_with_nif(_route1, _route2, _tolerance), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route's shift duration."
  def search_route_shift_duration_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route's max overtime."
  def search_route_max_overtime_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route's max duration (shift_duration + max_overtime)."
  def search_route_max_duration_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the route's unit overtime cost."
  def search_route_unit_overtime_cost_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the route has distance cost."
  def search_route_has_distance_cost_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the route has duration cost."
  def search_route_has_duration_cost_nif(_route), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets distance between two indices. Profile -1 uses route's default."
  def search_route_dist_between_nif(_route, _start, _end, _profile), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets distance at specific index. Profile -1 uses route's default."
  def search_route_dist_at_nif(_route, _idx, _profile), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets distance before index."
  def search_route_dist_before_nif(_route, _idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets distance after index."
  def search_route_dist_after_nif(_route, _idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates a search route from a list of visits."
  def make_search_route_nif(_problem_data, _visits, _idx, _vehicle_type), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # search::Route::Node NIFs
  # ---------------------------------------------------------------------------

  @doc "Creates a new search node."
  def create_search_node_nif(_problem_data, _loc), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the node's location (client index)."
  def search_node_client_nif(_node), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the node's index in the route."
  def search_node_idx_nif(_node), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the node's trip index."
  def search_node_trip_nif(_node), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the node is a depot."
  def search_node_is_depot_nif(_node), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the node is a start depot."
  def search_node_is_start_depot_nif(_node), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the node is an end depot."
  def search_node_is_end_depot_nif(_node), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the node is a reload depot."
  def search_node_is_reload_depot_nif(_node), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if the node has a route assigned."
  def search_node_has_route_nif(_node), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Exchange Operator NIFs
  # ---------------------------------------------------------------------------

  @doc "Creates an Exchange10 (relocate) operator."
  def create_exchange10_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates an Exchange11 (swap) operator."
  def create_exchange11_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates an Exchange20 operator."
  def create_exchange20_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates an Exchange21 operator."
  def create_exchange21_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates an Exchange22 operator."
  def create_exchange22_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates an Exchange30 operator."
  def create_exchange30_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates an Exchange31 operator."
  def create_exchange31_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates an Exchange32 operator."
  def create_exchange32_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates an Exchange33 operator."
  def create_exchange33_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates Exchange10 move cost."
  def exchange10_evaluate_nif(_op, _u, _v, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies Exchange10 move."
  def exchange10_apply_nif(_op, _u, _v), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates Exchange11 move cost."
  def exchange11_evaluate_nif(_op, _u, _v, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies Exchange11 move."
  def exchange11_apply_nif(_op, _u, _v), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates Exchange20 move cost."
  def exchange20_evaluate_nif(_op, _u, _v, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies Exchange20 move."
  def exchange20_apply_nif(_op, _u, _v), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates Exchange21 move cost."
  def exchange21_evaluate_nif(_op, _u, _v, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies Exchange21 move."
  def exchange21_apply_nif(_op, _u, _v), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates Exchange22 move cost."
  def exchange22_evaluate_nif(_op, _u, _v, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies Exchange22 move."
  def exchange22_apply_nif(_op, _u, _v), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates Exchange30 move cost."
  def exchange30_evaluate_nif(_op, _u, _v, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies Exchange30 move."
  def exchange30_apply_nif(_op, _u, _v), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates Exchange31 move cost."
  def exchange31_evaluate_nif(_op, _u, _v, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies Exchange31 move."
  def exchange31_apply_nif(_op, _u, _v), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates Exchange32 move cost."
  def exchange32_evaluate_nif(_op, _u, _v, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies Exchange32 move."
  def exchange32_apply_nif(_op, _u, _v), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates Exchange33 move cost."
  def exchange33_evaluate_nif(_op, _u, _v, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies Exchange33 move."
  def exchange33_apply_nif(_op, _u, _v), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Route Operator NIFs (SwapStar, SwapRoutes, SwapTails, RelocateWithDepot)
  # ---------------------------------------------------------------------------

  @doc "Creates a SwapStar operator with overlap_tolerance (0.0 to 1.0, use 1.0 to check all route pairs)."
  def create_swap_star_nif(_problem_data, _overlap_tolerance), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates SwapStar move cost between two routes."
  def swap_star_evaluate_nif(_op, _route1, _route2, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies SwapStar move between two routes."
  def swap_star_apply_nif(_op, _route1, _route2), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates a SwapRoutes operator."
  def create_swap_routes_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates SwapRoutes move cost between two routes."
  def swap_routes_evaluate_nif(_op, _route1, _route2, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies SwapRoutes move between two routes."
  def swap_routes_apply_nif(_op, _route1, _route2), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates a SwapTails operator."
  def create_swap_tails_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates a RelocateWithDepot operator."
  def create_relocate_with_depot_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates SwapTails move cost."
  def swap_tails_evaluate_nif(_op, _u, _v, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies SwapTails move."
  def swap_tails_apply_nif(_op, _u, _v), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Evaluates RelocateWithDepot move cost."
  def relocate_with_depot_evaluate_nif(_op, _u, _v, _evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Applies RelocateWithDepot move."
  def relocate_with_depot_apply_nif(_op, _u, _v), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if RelocateWithDepot is supported for the given problem data."
  @spec relocate_with_depot_supports_nif(reference()) :: boolean()
  def relocate_with_depot_supports_nif(_problem_data), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # Primitive Cost Functions
  # ---------------------------------------------------------------------------

  @doc """
  Computes the delta cost of inserting node U after node V in V's route.

  Returns 0 if the move is not possible (e.g., inserting a depot).
  """
  def insert_cost_nif(_u_node, _v_node, _problem_data, _cost_evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Computes the delta cost of removing node U from its route.

  Returns 0 if the move is not possible (e.g., removing a depot, node not in route).
  """
  def remove_cost_nif(_u_node, _problem_data, _cost_evaluator), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Computes the delta cost of inserting node U in place of node V.

  U must not be in a route, V must be in a route.
  Returns 0 if the move is not possible.
  """
  def inplace_cost_nif(_u_node, _v_node, _problem_data, _cost_evaluator), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # RandomNumberGenerator NIFs
  # ---------------------------------------------------------------------------

  @doc "Creates an RNG from a seed."
  @spec create_rng_from_seed_nif(non_neg_integer()) :: reference()
  def create_rng_from_seed_nif(_seed), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates an RNG from a 4-element state list."
  @spec create_rng_from_state_nif([non_neg_integer()]) :: {:ok, reference()} | {:error, term()}
  def create_rng_from_state_nif(_state), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns the minimum value the RNG can produce (0)."
  @spec rng_min_nif() :: non_neg_integer()
  def rng_min_nif, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns the maximum value the RNG can produce (2^32-1)."
  @spec rng_max_nif() :: non_neg_integer()
  def rng_max_nif, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Generates the next random integer. Returns {new_rng, value}."
  @spec rng_call_nif(reference()) :: {reference(), non_neg_integer()}
  def rng_call_nif(_rng), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Generates a random float in [0, 1]. Returns {new_rng, value}."
  @spec rng_rand_nif(reference()) :: {reference(), float()}
  def rng_rand_nif(_rng), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Generates a random integer in [0, high). Returns {new_rng, value}."
  @spec rng_randint_nif(reference(), non_neg_integer()) :: {reference(), non_neg_integer()}
  def rng_randint_nif(_rng, _high), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the current RNG state as a 4-element list."
  @spec rng_state_nif(reference()) :: [non_neg_integer()]
  def rng_state_nif(_rng), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # DynamicBitset NIFs
  # ---------------------------------------------------------------------------

  @doc "Creates a DynamicBitset with the given number of bits."
  @spec create_dynamic_bitset_nif(non_neg_integer()) :: reference()
  def create_dynamic_bitset_nif(_num_bits), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns the size (length) of the bitset."
  @spec dynamic_bitset_len_nif(reference()) :: non_neg_integer()
  def dynamic_bitset_len_nif(_bitset), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the bit at the given index."
  @spec dynamic_bitset_get_nif(reference(), non_neg_integer()) :: boolean()
  def dynamic_bitset_get_nif(_bitset, _idx), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Sets the bit at the given index. Returns a new bitset."
  @spec dynamic_bitset_set_bit_nif(reference(), non_neg_integer(), boolean()) :: reference()
  def dynamic_bitset_set_bit_nif(_bitset, _idx, _value), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns true if all bits are set."
  @spec dynamic_bitset_all_nif(reference()) :: boolean()
  def dynamic_bitset_all_nif(_bitset), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns true if any bit is set."
  @spec dynamic_bitset_any_nif(reference()) :: boolean()
  def dynamic_bitset_any_nif(_bitset), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns true if no bits are set."
  @spec dynamic_bitset_none_nif(reference()) :: boolean()
  def dynamic_bitset_none_nif(_bitset), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns the number of set bits."
  @spec dynamic_bitset_count_nif(reference()) :: non_neg_integer()
  def dynamic_bitset_count_nif(_bitset), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Sets all bits to 1. Returns a new bitset."
  @spec dynamic_bitset_set_all_nif(reference()) :: reference()
  def dynamic_bitset_set_all_nif(_bitset), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Resets all bits to 0. Returns a new bitset."
  @spec dynamic_bitset_reset_all_nif(reference()) :: reference()
  def dynamic_bitset_reset_all_nif(_bitset), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Bitwise OR of two bitsets. Returns a new bitset."
  @spec dynamic_bitset_or_nif(reference(), reference()) :: reference()
  def dynamic_bitset_or_nif(_a, _b), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Bitwise AND of two bitsets. Returns a new bitset."
  @spec dynamic_bitset_and_nif(reference(), reference()) :: reference()
  def dynamic_bitset_and_nif(_a, _b), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Bitwise XOR of two bitsets. Returns a new bitset."
  @spec dynamic_bitset_xor_nif(reference(), reference()) :: reference()
  def dynamic_bitset_xor_nif(_a, _b), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Bitwise NOT of a bitset. Returns a new bitset."
  @spec dynamic_bitset_not_nif(reference()) :: reference()
  def dynamic_bitset_not_nif(_bitset), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks if two bitsets are equal."
  @spec dynamic_bitset_eq_nif(reference(), reference()) :: boolean()
  def dynamic_bitset_eq_nif(_a, _b), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # DurationSegment NIFs
  # ---------------------------------------------------------------------------

  @doc "Creates a DurationSegment from raw parameters."
  @spec create_duration_segment_nif(
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer(),
          integer()
        ) :: reference()
  def create_duration_segment_nif(
        _duration,
        _time_warp,
        _start_early,
        _start_late,
        _release_time,
        _cum_duration,
        _cum_time_warp,
        _prev_end_late
      ), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Merges two segments with an edge duration."
  @spec duration_segment_merge_nif(integer(), reference(), reference()) :: reference()
  def duration_segment_merge_nif(_edge_duration, _first, _second), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the duration of a segment."
  @spec duration_segment_duration_nif(reference()) :: integer()
  def duration_segment_duration_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the time warp of a segment, optionally with max_duration constraint."
  @spec duration_segment_time_warp_nif(reference(), integer()) :: integer()
  def duration_segment_time_warp_nif(_seg, _max_duration), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the start_early of a segment."
  @spec duration_segment_start_early_nif(reference()) :: integer()
  def duration_segment_start_early_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the start_late of a segment."
  @spec duration_segment_start_late_nif(reference()) :: integer()
  def duration_segment_start_late_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the end_early of a segment."
  @spec duration_segment_end_early_nif(reference()) :: integer()
  def duration_segment_end_early_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the end_late of a segment."
  @spec duration_segment_end_late_nif(reference()) :: integer()
  def duration_segment_end_late_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the prev_end_late of a segment."
  @spec duration_segment_prev_end_late_nif(reference()) :: integer()
  def duration_segment_prev_end_late_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the release_time of a segment."
  @spec duration_segment_release_time_nif(reference()) :: integer()
  def duration_segment_release_time_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Gets the slack of a segment."
  @spec duration_segment_slack_nif(reference()) :: integer()
  def duration_segment_slack_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Finalises a segment at the back."
  @spec duration_segment_finalise_back_nif(reference()) :: reference()
  def duration_segment_finalise_back_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Finalises a segment at the front."
  @spec duration_segment_finalise_front_nif(reference()) :: reference()
  def duration_segment_finalise_front_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # LoadSegment NIFs
  # ---------------------------------------------------------------------------

  @doc "Creates a new LoadSegment from raw parameters."
  @spec create_load_segment_nif(integer(), integer(), integer(), integer()) :: reference()
  def create_load_segment_nif(_delivery, _pickup, _load, _excess_load), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Merges two LoadSegments."
  @spec load_segment_merge_nif(reference(), reference()) :: reference()
  def load_segment_merge_nif(_first, _second), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Finalises a LoadSegment with capacity."
  @spec load_segment_finalise_nif(reference(), integer()) :: reference()
  def load_segment_finalise_nif(_seg, _capacity), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns delivery amount."
  @spec load_segment_delivery_nif(reference()) :: integer()
  def load_segment_delivery_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns pickup amount."
  @spec load_segment_pickup_nif(reference()) :: integer()
  def load_segment_pickup_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns load."
  @spec load_segment_load_nif(reference()) :: integer()
  def load_segment_load_nif(_seg), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns excess load with capacity constraint."
  @spec load_segment_excess_load_nif(reference(), integer()) :: integer()
  def load_segment_excess_load_nif(_seg, _capacity), do: :erlang.nif_error(:nif_not_loaded)

  # ---------------------------------------------------------------------------
  # PerturbationManager NIFs
  # ---------------------------------------------------------------------------

  @doc "Creates a PerturbationManager with given min/max perturbations."
  @spec create_perturbation_manager_nif(integer(), integer()) :: reference()
  def create_perturbation_manager_nif(_min, _max), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns the min_perturbations parameter."
  @spec perturbation_manager_min_perturbations_nif(reference()) :: integer()
  def perturbation_manager_min_perturbations_nif(_pm), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns the max_perturbations parameter."
  @spec perturbation_manager_max_perturbations_nif(reference()) :: integer()
  def perturbation_manager_max_perturbations_nif(_pm), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns the current number of perturbations to apply."
  @spec perturbation_manager_num_perturbations_nif(reference()) :: integer()
  def perturbation_manager_num_perturbations_nif(_pm), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Shuffles to pick a new random number of perturbations."
  @spec perturbation_manager_shuffle_nif(reference(), reference()) :: reference()
  def perturbation_manager_shuffle_nif(_pm, _rng), do: :erlang.nif_error(:nif_not_loaded)
end

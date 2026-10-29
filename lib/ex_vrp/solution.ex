defmodule ExVrp.Solution do
  @moduledoc """
  Represents a solution to a VRP.

  A solution consists of routes (one per vehicle used) and provides
  functions to query costs, distances, feasibility, and detailed schedules.

  ## Accessing Solutions

  Solutions are returned as `result.best` from the solver:

      {:ok, result} = ExVrp.solve(model)
      solution = result.best

      solution.routes       #=> [[1, 3], [2]]
      solution.distance     #=> 4521
      solution.is_feasible  #=> true
      solution.num_clients  #=> 3

  ## Querying Routes

  Use `routes/1` to get `ExVrp.Route` structs with full query capabilities:

      routes = ExVrp.Solution.routes(solution)

      for route <- routes do
        IO.puts("Distance: \#{ExVrp.Route.distance(route)}")
        IO.puts("Duration: \#{ExVrp.Route.duration(route)}")
        IO.puts("Vehicle type: \#{route.vehicle_type}")
      end

  Or query route properties directly by index:

      ExVrp.Solution.route_distance(solution, 0)
      ExVrp.Solution.route_delivery(solution, 0)
      ExVrp.Solution.route_feasible?(solution, 0)

  ## Schedules

  Get detailed timing for each visit in a route:

      schedule = ExVrp.Solution.route_schedule(solution, 0)

      for visit <- schedule do
        IO.puts("Location \#{visit.location}: \#{visit.start_service}-\#{visit.end_service}")
      end

  ## Constraint Violations

  Check for specific constraint violations:

      ExVrp.Solution.has_time_warp?(solution)
      ExVrp.Solution.has_excess_load?(solution)
      ExVrp.Solution.has_excess_distance?(solution)
      ExVrp.Solution.time_warp(solution)        #=> total time warp
      ExVrp.Solution.excess_load(solution)       #=> per-dimension excess

  ## Unassigned Clients

  For prize-collecting problems, check which clients were not visited:

      ExVrp.Solution.unassigned(solution)  #=> [4, 7]

  """

  alias ExVrp.Native
  alias ExVrp.WarmStart

  @type t :: %__MODULE__{
          routes: [[non_neg_integer()]],
          solution_ref: reference() | nil,
          problem_data: reference() | nil,
          distance: non_neg_integer(),
          duration: non_neg_integer(),
          num_clients: non_neg_integer(),
          is_feasible: boolean(),
          is_complete: boolean(),
          stats: map() | nil
        }

  defstruct routes: [],
            solution_ref: nil,
            problem_data: nil,
            distance: 0,
            duration: 0,
            num_clients: 0,
            is_feasible: true,
            is_complete: true,
            stats: nil

  @typedoc """
  One vehicle's warm-start visits, as `warm_start/1` returns them and `:initial_routes` takes
  them: a flat client list (a single trip), or its trips, where the first trip's `reload_depot` is
  `nil` and each later trip names the reload depot it starts from. A `:break` among the clients is
  a break taken there.
  """
  @type warm_start_visits ::
          [warm_start_client()]
          | {:trips, [%{reload_depot: non_neg_integer() | nil, clients: [warm_start_client()]}]}

  @typedoc """
  A client index, or `:break` for a break taken at that point of the route.
  """
  @type warm_start_client :: non_neg_integer() | :break

  @doc """
  Returns the total distance of the solution.
  """
  @spec distance(t()) :: non_neg_integer()
  def distance(%__MODULE__{distance: distance}), do: distance

  @doc """
  Returns the total duration of the solution.
  """
  @spec duration(t()) :: non_neg_integer()
  def duration(%__MODULE__{duration: duration}), do: duration

  @doc """
  Returns the solution's objective, or its distance when called without an evaluator.

  `cost/2` prices the solution the way the solver ranks it: distance, duration and overtime cost,
  fixed vehicle cost, reload cost and `penalty_cost/1`, plus the prize of every client it leaves
  unvisited. It is `:infinity` for an infeasible solution. Build the evaluator with
  `ExVrp.PenaltyManager.init_from/2` and `ExVrp.PenaltyManager.cost_evaluator/1`; the penalties
  it carries only matter to `penalised_cost/2`.

  `cost/1` is only the distance, so it equals the objective only on a model where distance is all
  that is priced, at a `:unit_distance_cost` of 1. `ExVrp.IteratedLocalSearch.Result.cost/1` gives
  the objective of a solve's best solution without an evaluator.
  """
  @spec cost(t()) :: non_neg_integer()
  @spec cost(t(), reference()) :: non_neg_integer() | :infinity
  def cost(%__MODULE__{distance: distance}), do: distance

  def cost(%__MODULE__{solution_ref: solution_ref}, cost_evaluator) do
    Native.solution_cost(solution_ref, cost_evaluator)
  end

  @doc """
  Returns `cost/2` plus the evaluator's penalties on excess load, time warp and excess distance,
  so it is finite for an infeasible solution too. This is what the search compares; see
  `cost/2` for building the evaluator.
  """
  @spec penalised_cost(t(), reference()) :: non_neg_integer()
  def penalised_cost(%__MODULE__{solution_ref: solution_ref}, cost_evaluator) do
    Native.solution_penalised_cost(solution_ref, cost_evaluator)
  end

  @doc """
  Returns the number of routes in the solution.
  """
  @spec num_routes(t()) :: non_neg_integer()
  def num_routes(%__MODULE__{routes: routes}) do
    length(routes)
  end

  @doc """
  Returns the route at the given index as a Route struct.

  The returned Route struct has its `solution_ref` and `route_idx` populated,
  enabling methods like `Route.distance/1`, `Route.feasible?/1`, etc.

  ## Example

      {:ok, result} = Solver.solve(model)
      route = Solution.route(result.best, 0)
      Route.distance(route)

  """
  @spec route(t(), non_neg_integer()) :: ExVrp.Route.t()
  def route(%__MODULE__{solution_ref: ref, routes: raw_routes}, idx) do
    %ExVrp.Route{
      visits: Enum.at(raw_routes, idx, []),
      solution_ref: ref,
      route_idx: idx
    }
  end

  @doc """
  Returns all routes as Route structs.

  Each returned Route struct has its `solution_ref` and `route_idx` populated,
  enabling methods like `Route.distance/1`, `Route.feasible?/1`, etc.

  ## Example

      {:ok, result} = Solver.solve(model)
      routes = Solution.routes(result.best)

      Enum.each(routes, fn route ->
        IO.puts("Route distance: \#{Route.distance(route)}")
      end)

  """
  @spec routes(t()) :: [ExVrp.Route.t()]
  def routes(%__MODULE__{solution_ref: ref, routes: raw_routes}) do
    raw_routes
    |> Enum.with_index()
    |> Enum.map(fn {visits, idx} ->
      %ExVrp.Route{
        visits: visits,
        solution_ref: ref,
        route_idx: idx,
        vehicle_type: Native.solution_route_vehicle_type(ref, idx),
        start_depot: Native.solution_route_start_depot(ref, idx),
        end_depot: Native.solution_route_end_depot(ref, idx)
      }
    end)
  end

  @doc """
  Returns this solution as an `:initial_routes` warm start, so a solve can resume from it.

  One entry per vehicle type, in vehicle type order: `[]` for a vehicle type without a route, a
  flat client list for a single-trip route, and `{:trips, [...]}` for a route that reloads, so
  its trip boundaries survive the round trip. `routes` is not a substitute: it lists a route's
  clients without its reloads, and seeding with it merges every trip into one load.

  `:initial_routes` holds at most one route per vehicle type, so a solution that runs several
  routes on one vehicle type returns `{:error, {:vehicle_type_has_several_routes, vehicle_type}}`.

  Each break comes back as a `:break` marker where it fell, rather than as its client index: those
  follow the model's own clients, so they would not survive a model that changed. The next solve
  gives every marker a break of its own, and keeps it there unless moving it pays.

  ## Example

      {:ok, result} = ExVrp.solve(model)
      {:ok, initial_routes} = ExVrp.Solution.warm_start(result.best)
      {:ok, resumed} = ExVrp.solve(updated_model, initial_routes: initial_routes)

  """
  @spec warm_start(t()) ::
          {:ok, [warm_start_visits()]}
          | {:error, {:vehicle_type_has_several_routes, non_neg_integer()}}
  def warm_start(%__MODULE__{solution_ref: ref, problem_data: problem_data}) do
    breaks = problem_data |> Native.problem_data_break_clients() |> MapSet.new()
    vehicle_type_trips = ref |> WarmStart.vehicle_type_trips() |> WarmStart.with_break_markers(breaks)

    vehicle_type_trips
    |> Enum.frequencies_by(fn {vehicle_type, _trips} -> vehicle_type end)
    |> Enum.find(fn {_vehicle_type, num_routes} -> num_routes > 1 end)
    |> warm_start_by_vehicle_type(vehicle_type_trips, Native.problem_data_num_vehicle_types(problem_data))
  end

  defp warm_start_by_vehicle_type({vehicle_type, _num_routes}, _vehicle_type_trips, _num_vehicle_types),
    do: {:error, {:vehicle_type_has_several_routes, vehicle_type}}

  defp warm_start_by_vehicle_type(nil, vehicle_type_trips, num_vehicle_types) do
    visits_by_vehicle_type =
      Map.new(vehicle_type_trips, fn {vehicle_type, trips} -> {vehicle_type, WarmStart.from_trips(trips)} end)

    {:ok, Enum.map(0..(num_vehicle_types - 1)//1, &Map.get(visits_by_vehicle_type, &1, []))}
  end

  @doc """
  Returns the number of assigned clients in the solution.
  """
  @spec num_clients(t()) :: non_neg_integer()
  def num_clients(%__MODULE__{num_clients: num_clients}), do: num_clients

  @doc """
  Checks if the solution is feasible (satisfies all constraints).
  """
  @spec feasible?(t()) :: boolean()

  # ==========================================
  # Solution-Level Aggregate Functions (PyVRP parity)
  # ==========================================

  def feasible?(%__MODULE__{is_feasible: feasible}), do: feasible

  @doc """
  Checks if the solution is complete (visits all required clients).
  """
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{is_complete: complete}), do: complete

  @doc """
  Checks if the solution satisfies both kinds of group constraint.

  Two unrelated constraints share this one flag: the mutually exclusive client
  groups a disjunctive time window expands into, and the same-vehicle groups
  that keep a set of clients on one route. False does not say which broke —
  pair it with `num_same_vehicle_violations/1`, which is zero when the
  violation is a client group.
  """
  @spec group_feasible?(t()) :: boolean()
  def group_feasible?(%__MODULE__{solution_ref: solution_ref}) do
    Native.solution_is_group_feasible(solution_ref)
  end

  @doc """
  How many same-vehicle groups this solution splits across routes.
  """
  @spec num_same_vehicle_violations(t()) :: non_neg_integer()
  def num_same_vehicle_violations(%__MODULE__{solution_ref: solution_ref}) do
    Native.solution_num_same_vehicle_violations(solution_ref)
  end

  @doc """
  Returns a list of unassigned client indices.
  """
  @spec unassigned(t()) :: [non_neg_integer()]
  def unassigned(%__MODULE__{solution_ref: solution_ref}) do
    Native.solution_unassigned(solution_ref)
  end

  @doc """
  Returns the total time warp of the solution (sum across all routes).

  Includes `drive_excess/1` and each route's `ExVrp.Route.clock_excess/1`
  and `ExVrp.Route.work_clock_excess/1`.
  """
  @spec time_warp(t()) :: non_neg_integer()
  def time_warp(%__MODULE__{} = sol) do
    sum_over_routes(sol, &route_time_warp/2)
  end

  @doc """
  Returns the total excess load of the solution per dimension.
  """
  @spec excess_load(t()) :: [non_neg_integer()]
  def excess_load(%__MODULE__{routes: []}), do: []

  def excess_load(%__MODULE__{routes: routes} = sol) do
    routes
    |> Enum.with_index()
    |> Enum.map(fn {_route, idx} -> route_excess_load(sol, idx) end)
    |> sum_per_dimension()
  end

  defp sum_per_dimension([]), do: []

  defp sum_per_dimension(excess_lists) do
    excess_lists
    |> Enum.zip()
    |> Enum.map(fn dims -> dims |> Tuple.to_list() |> Enum.sum() end)
  end

  @doc """
  Returns the total excess distance of the solution (sum across all routes).
  """
  @spec excess_distance(t()) :: non_neg_integer()
  def excess_distance(%__MODULE__{} = sol) do
    sum_over_routes(sol, &route_excess_distance/2)
  end

  @doc """
  Returns the total overtime of the solution (sum across all routes).
  """
  @spec overtime(t()) :: non_neg_integer()
  def overtime(%__MODULE__{} = sol) do
    sum_over_routes(sol, &route_overtime/2)
  end

  @doc """
  Returns the total travel past `:max_drive` of the solution (sum across all
  routes). Also counted in `time_warp/1`.
  """
  @spec drive_excess(t()) :: non_neg_integer()
  def drive_excess(%__MODULE__{} = sol) do
    sum_over_routes(sol, &route_drive_excess/2)
  end

  @doc """
  Returns the total fixed vehicle cost of the solution.
  """
  @spec fixed_vehicle_cost(t()) :: non_neg_integer()
  def fixed_vehicle_cost(%__MODULE__{solution_ref: solution_ref}) do
    Native.solution_fixed_vehicle_cost(solution_ref)
  end

  @doc """
  Returns the total penalty cost of this solution.

  Subtracting this from `cost/1` gives the solution's real monetary cost,
  with constraint penalties excluded by construction.
  """
  @spec penalty_cost(t()) :: integer()
  def penalty_cost(%__MODULE__{solution_ref: solution_ref}) do
    Native.solution_penalty_cost(solution_ref)
  end

  @doc """
  Returns the vehicle-lock share of this solution's `penalty_cost/1`.
  """
  @spec lock_cost(t()) :: non_neg_integer()
  def lock_cost(%__MODULE__{solution_ref: solution_ref}) do
    Native.solution_lock_cost(solution_ref)
  end

  @doc """
  Returns how many visits in this solution the visiting route's own routing
  profile forbids.

  Always zero for a solution the solver produced — `ExVrp.Model.set_forbidden/2`
  prunes rather than prices, so no move should ever place one. A nonzero value
  means a violation reached the objective unnoticed and is a bug. It is
  deliberately kept out of `feasible?/1`: a violation carries no penalty
  gradient, so failing the solution would leave the search unable to repair it.
  """
  @spec num_forbidden_visits(t()) :: non_neg_integer()
  def num_forbidden_visits(%__MODULE__{solution_ref: solution_ref}) do
    Native.solution_num_forbidden_visits(solution_ref)
  end

  @doc """
  Returns how many shipments (see `ExVrp.Shipment`) have their pickup visited
  but not their delivery: goods collected and brought back to the depot rather
  than dropped off. The delivery is then in `unassigned/1`, like any client
  left unplanned.
  """
  @spec num_pickups_without_delivery(t()) :: non_neg_integer()
  def num_pickups_without_delivery(%__MODULE__{solution_ref: solution_ref}) do
    Native.solution_num_pickups_without_delivery(solution_ref)
  end

  @doc """
  Returns the total distance cost of the solution.
  """
  @spec distance_cost(t()) :: non_neg_integer()
  def distance_cost(%__MODULE__{} = sol) do
    sum_over_routes(sol, &route_distance_cost/2)
  end

  @doc """
  Returns the total duration cost of the solution.
  """
  @spec duration_cost(t()) :: non_neg_integer()
  def duration_cost(%__MODULE__{} = sol) do
    sum_over_routes(sol, &route_duration_cost/2)
  end

  # ==========================================
  # New Route Query Functions (PyVRP parity)
  # ==========================================

  @doc """
  Returns the total reload cost of the solution.
  """
  @spec reload_cost(t()) :: non_neg_integer()
  def reload_cost(%__MODULE__{} = sol) do
    sum_over_routes(sol, &route_reload_cost/2)
  end

  @doc """
  Returns true if the solution has any excess load.
  """
  @spec has_excess_load?(t()) :: boolean()
  def has_excess_load?(%__MODULE__{} = sol) do
    Enum.any?(excess_load(sol), &(&1 > 0))
  end

  @doc """
  Returns true if the solution has any time warp.
  """
  @spec has_time_warp?(t()) :: boolean()
  def has_time_warp?(%__MODULE__{} = sol) do
    time_warp(sol) > 0
  end

  @doc """
  Returns true if the solution has any excess distance.
  """
  @spec has_excess_distance?(t()) :: boolean()
  def has_excess_distance?(%__MODULE__{} = sol) do
    excess_distance(sol) > 0
  end

  # Helper to sum a route function over all routes
  defp sum_over_routes(%__MODULE__{routes: routes} = sol, route_fn) do
    Enum.reduce(0..(length(routes) - 1), 0, fn idx, acc ->
      acc + route_fn.(sol, idx)
    end)
  end

  @doc """
  `ExVrp.Route.distance/1` of the route at `route_idx`.
  """
  @spec route_distance(t(), non_neg_integer()) :: non_neg_integer()
  def route_distance(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_distance(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.duration/1` of the route at `route_idx`.
  """
  @spec route_duration(t(), non_neg_integer()) :: non_neg_integer()
  def route_duration(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_duration(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.delivery/1` of the route at `route_idx`.
  """
  @spec route_delivery(t(), non_neg_integer()) :: [non_neg_integer()]
  def route_delivery(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_delivery(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.pickup/1` of the route at `route_idx`.
  """
  @spec route_pickup(t(), non_neg_integer()) :: [non_neg_integer()]
  def route_pickup(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_pickup(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.feasible?/1` of the route at `route_idx`.
  """
  @spec route_feasible?(t(), non_neg_integer()) :: boolean()
  def route_feasible?(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_is_feasible(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.excess_load/1` of the route at `route_idx`.
  """
  @spec route_excess_load(t(), non_neg_integer()) :: [non_neg_integer()]
  def route_excess_load(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_excess_load(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.time_warp/1` of the route at `route_idx`.
  """
  @spec route_time_warp(t(), non_neg_integer()) :: non_neg_integer()
  def route_time_warp(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_time_warp(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.excess_distance/1` of the route at `route_idx`.
  """
  @spec route_excess_distance(t(), non_neg_integer()) :: non_neg_integer()
  def route_excess_distance(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_excess_distance(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.overtime/1` of the route at `route_idx`.
  """
  @spec route_overtime(t(), non_neg_integer()) :: non_neg_integer()
  def route_overtime(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_overtime(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.drive_excess/1` of the route at `route_idx`.
  """
  @spec route_drive_excess(t(), non_neg_integer()) :: non_neg_integer()
  def route_drive_excess(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_drive_excess(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.has_excess_load?/1` of the route at `route_idx`.
  """
  @spec route_has_excess_load?(t(), non_neg_integer()) :: boolean()
  def route_has_excess_load?(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_has_excess_load(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.has_time_warp?/1` of the route at `route_idx`.
  """
  @spec route_has_time_warp?(t(), non_neg_integer()) :: boolean()
  def route_has_time_warp?(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_has_time_warp(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.has_excess_distance?/1` of the route at `route_idx`.
  """
  @spec route_has_excess_distance?(t(), non_neg_integer()) :: boolean()
  def route_has_excess_distance?(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_has_excess_distance(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.vehicle_type/1` of the route at `route_idx`.
  """
  @spec route_vehicle_type(t(), non_neg_integer()) :: non_neg_integer()
  def route_vehicle_type(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_vehicle_type(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.start_depot/1` of the route at `route_idx`.
  """
  @spec route_start_depot(t(), non_neg_integer()) :: non_neg_integer()
  def route_start_depot(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_start_depot(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.end_depot/1` of the route at `route_idx`.
  """
  @spec route_end_depot(t(), non_neg_integer()) :: non_neg_integer()
  def route_end_depot(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_end_depot(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.num_trips/1` of the route at `route_idx`.
  """
  @spec route_num_trips(t(), non_neg_integer()) :: non_neg_integer()
  def route_num_trips(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_num_trips(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.start_time/1` of the route at `route_idx`.
  """
  @spec route_start_time(t(), non_neg_integer()) :: non_neg_integer()
  def route_start_time(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_start_time(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.end_time/1` of the route at `route_idx`.
  """
  @spec route_end_time(t(), non_neg_integer()) :: non_neg_integer()
  def route_end_time(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_end_time(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.slack/1` of the route at `route_idx`.
  """
  @spec route_slack(t(), non_neg_integer()) :: non_neg_integer()
  def route_slack(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_slack(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.service_duration/1` of the route at `route_idx`.
  """
  @spec route_service_duration(t(), non_neg_integer()) :: non_neg_integer()
  def route_service_duration(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_service_duration(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.travel_duration/1` of the route at `route_idx`.
  """
  @spec route_travel_duration(t(), non_neg_integer()) :: non_neg_integer()
  def route_travel_duration(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_travel_duration(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.wait_duration/1` of the route at `route_idx`.
  """
  @spec route_wait_duration(t(), non_neg_integer()) :: non_neg_integer()
  def route_wait_duration(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_wait_duration(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.distance_cost/1` of the route at `route_idx`.
  """
  @spec route_distance_cost(t(), non_neg_integer()) :: non_neg_integer()
  def route_distance_cost(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_distance_cost(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.duration_cost/1` of the route at `route_idx`.
  """
  @spec route_duration_cost(t(), non_neg_integer()) :: non_neg_integer()
  def route_duration_cost(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_duration_cost(solution_ref, route_idx)
  end

  @doc """
  Returns what the route at `route_idx` pays for its reloads: the `:reload_cost` of the depot
  each later trip starts from.
  """
  @spec route_reload_cost(t(), non_neg_integer()) :: non_neg_integer()
  def route_reload_cost(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_reload_cost(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.prizes/1` of the route at `route_idx`.
  """
  @spec route_prizes(t(), non_neg_integer()) :: non_neg_integer()
  def route_prizes(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_prizes(solution_ref, route_idx)
  end

  @doc """
  `ExVrp.Route.visits/1` of the route at `route_idx`.
  """
  @spec route_visits(t(), non_neg_integer()) :: [non_neg_integer()]
  def route_visits(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    Native.solution_route_visits(solution_ref, route_idx)
  end

  @doc """
  Returns the schedule of a specific route.

  The schedule contains detailed timing information for each visit, including
  service start/end times, waiting times, and any time warp (late arrival).

  ## Example

      schedule = Solution.route_schedule(solution, 0)

      Enum.each(schedule, fn visit ->
        IO.puts("Location \#{visit.location}: \#{visit.start_service}-\#{visit.end_service}")
      end)

  """
  @spec route_schedule(t(), non_neg_integer()) :: [ExVrp.ScheduledVisit.t()]
  def route_schedule(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    solution_ref
    |> Native.solution_route_schedule(route_idx)
    |> Enum.map(&ExVrp.ScheduledVisit.from_tuple/1)
  end
end

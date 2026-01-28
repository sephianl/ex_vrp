defmodule ExVrp.Solution do
  @moduledoc """
  Represents a solution to a VRP.

  A solution consists of routes (one per vehicle used) and provides
  methods to compute costs, distances, and validate feasibility.
  """

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
  Returns the total cost of the solution.

  When called with a cost evaluator, uses that evaluator.
  When called without, uses the distance as the cost (default unit_distance_cost=1).
  """
  @spec cost(t()) :: non_neg_integer()
  @spec cost(t(), reference()) :: non_neg_integer() | :infinity
  def cost(%__MODULE__{distance: distance}), do: distance

  def cost(%__MODULE__{solution_ref: solution_ref}, cost_evaluator) do
    ExVrp.Native.solution_cost(solution_ref, cost_evaluator)
  end

  @doc """
  Returns the penalised cost of the solution given a cost evaluator.
  """
  @spec penalised_cost(t(), reference()) :: non_neg_integer()
  def penalised_cost(%__MODULE__{solution_ref: solution_ref}, cost_evaluator) do
    ExVrp.Native.solution_penalised_cost(solution_ref, cost_evaluator)
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
        vehicle_type: ExVrp.Native.solution_route_vehicle_type(ref, idx),
        start_depot: ExVrp.Native.solution_route_start_depot(ref, idx),
        end_depot: ExVrp.Native.solution_route_end_depot(ref, idx)
      }
    end)
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
  def feasible?(%__MODULE__{is_feasible: feasible}), do: feasible

  @doc """
  Checks if the solution is complete (visits all required clients).
  """
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{is_complete: complete}), do: complete

  @doc """
  Checks if the solution is group feasible (same-vehicle constraints satisfied).

  Returns true if all clients in each same-vehicle group that are visited
  are on the same route.
  """
  @spec group_feasible?(t()) :: boolean()
  def group_feasible?(%__MODULE__{solution_ref: solution_ref}) do
    ExVrp.Native.solution_is_group_feasible(solution_ref)
  end

  @doc """
  Returns a list of unassigned client indices.
  """
  @spec unassigned(t()) :: [non_neg_integer()]
  def unassigned(%__MODULE__{solution_ref: solution_ref}) do
    ExVrp.Native.solution_unassigned(solution_ref)
  end

  # ==========================================
  # Solution-Level Aggregate Functions (PyVRP parity)
  # ==========================================

  @doc """
  Returns the total time warp of the solution (sum across all routes).
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
  Returns the total fixed vehicle cost of the solution.
  """
  @spec fixed_vehicle_cost(t()) :: non_neg_integer()
  def fixed_vehicle_cost(%__MODULE__{solution_ref: solution_ref}) do
    ExVrp.Native.solution_fixed_vehicle_cost(solution_ref)
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
  Returns the distance of a specific route in the solution.
  """
  @spec route_distance(t(), non_neg_integer()) :: non_neg_integer()
  def route_distance(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_distance(solution_ref, route_idx)
  end

  @doc """
  Returns the duration of a specific route in the solution.
  """
  @spec route_duration(t(), non_neg_integer()) :: non_neg_integer()
  def route_duration(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_duration(solution_ref, route_idx)
  end

  @doc """
  Returns the delivery load of a specific route in the solution.
  """
  @spec route_delivery(t(), non_neg_integer()) :: [non_neg_integer()]
  def route_delivery(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_delivery(solution_ref, route_idx)
  end

  @doc """
  Returns the pickup load of a specific route in the solution.
  """
  @spec route_pickup(t(), non_neg_integer()) :: [non_neg_integer()]
  def route_pickup(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_pickup(solution_ref, route_idx)
  end

  @doc """
  Checks if a specific route in the solution is feasible.
  """
  @spec route_feasible?(t(), non_neg_integer()) :: boolean()
  def route_feasible?(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_is_feasible(solution_ref, route_idx)
  end

  # ==========================================
  # New Route Query Functions (PyVRP parity)
  # ==========================================

  @doc """
  Returns the excess load of a specific route (per dimension).
  """
  @spec route_excess_load(t(), non_neg_integer()) :: [non_neg_integer()]
  def route_excess_load(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_excess_load(solution_ref, route_idx)
  end

  @doc """
  Returns the time warp of a specific route.
  """
  @spec route_time_warp(t(), non_neg_integer()) :: non_neg_integer()
  def route_time_warp(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_time_warp(solution_ref, route_idx)
  end

  @doc """
  Returns the excess distance of a specific route.
  """
  @spec route_excess_distance(t(), non_neg_integer()) :: non_neg_integer()
  def route_excess_distance(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_excess_distance(solution_ref, route_idx)
  end

  @doc """
  Returns the overtime of a specific route.
  """
  @spec route_overtime(t(), non_neg_integer()) :: non_neg_integer()
  def route_overtime(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_overtime(solution_ref, route_idx)
  end

  @doc """
  Checks if a specific route has excess load.
  """
  @spec route_has_excess_load?(t(), non_neg_integer()) :: boolean()
  def route_has_excess_load?(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_has_excess_load(solution_ref, route_idx)
  end

  @doc """
  Checks if a specific route has time warp.
  """
  @spec route_has_time_warp?(t(), non_neg_integer()) :: boolean()
  def route_has_time_warp?(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_has_time_warp(solution_ref, route_idx)
  end

  @doc """
  Checks if a specific route has excess distance.
  """
  @spec route_has_excess_distance?(t(), non_neg_integer()) :: boolean()
  def route_has_excess_distance?(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_has_excess_distance(solution_ref, route_idx)
  end

  @doc """
  Returns the vehicle type of a specific route.
  """
  @spec route_vehicle_type(t(), non_neg_integer()) :: non_neg_integer()
  def route_vehicle_type(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_vehicle_type(solution_ref, route_idx)
  end

  @doc """
  Returns the start depot of a specific route.
  """
  @spec route_start_depot(t(), non_neg_integer()) :: non_neg_integer()
  def route_start_depot(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_start_depot(solution_ref, route_idx)
  end

  @doc """
  Returns the end depot of a specific route.
  """
  @spec route_end_depot(t(), non_neg_integer()) :: non_neg_integer()
  def route_end_depot(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_end_depot(solution_ref, route_idx)
  end

  @doc """
  Returns the number of trips in a specific route.
  """
  @spec route_num_trips(t(), non_neg_integer()) :: non_neg_integer()
  def route_num_trips(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_num_trips(solution_ref, route_idx)
  end

  @doc """
  Returns the centroid of a specific route as {x, y}.
  """
  @spec route_centroid(t(), non_neg_integer()) :: {float(), float()}
  def route_centroid(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_centroid(solution_ref, route_idx)
  end

  @doc """
  Returns the start time of a specific route.
  """
  @spec route_start_time(t(), non_neg_integer()) :: non_neg_integer()
  def route_start_time(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_start_time(solution_ref, route_idx)
  end

  @doc """
  Returns the end time of a specific route.
  """
  @spec route_end_time(t(), non_neg_integer()) :: non_neg_integer()
  def route_end_time(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_end_time(solution_ref, route_idx)
  end

  @doc """
  Returns the slack time of a specific route.
  """
  @spec route_slack(t(), non_neg_integer()) :: non_neg_integer()
  def route_slack(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_slack(solution_ref, route_idx)
  end

  @doc """
  Returns the service duration of a specific route.
  """
  @spec route_service_duration(t(), non_neg_integer()) :: non_neg_integer()
  def route_service_duration(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_service_duration(solution_ref, route_idx)
  end

  @doc """
  Returns the travel duration of a specific route.
  """
  @spec route_travel_duration(t(), non_neg_integer()) :: non_neg_integer()
  def route_travel_duration(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_travel_duration(solution_ref, route_idx)
  end

  @doc """
  Returns the wait duration of a specific route.
  """
  @spec route_wait_duration(t(), non_neg_integer()) :: non_neg_integer()
  def route_wait_duration(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_wait_duration(solution_ref, route_idx)
  end

  @doc """
  Returns the distance cost of a specific route.
  """
  @spec route_distance_cost(t(), non_neg_integer()) :: non_neg_integer()
  def route_distance_cost(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_distance_cost(solution_ref, route_idx)
  end

  @doc """
  Returns the duration cost of a specific route.
  """
  @spec route_duration_cost(t(), non_neg_integer()) :: non_neg_integer()
  def route_duration_cost(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_duration_cost(solution_ref, route_idx)
  end

  @doc """
  Returns the reload cost of a specific route.
  """
  @spec route_reload_cost(t(), non_neg_integer()) :: non_neg_integer()
  def route_reload_cost(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_reload_cost(solution_ref, route_idx)
  end

  @doc """
  Returns the prizes collected on a specific route.
  """
  @spec route_prizes(t(), non_neg_integer()) :: non_neg_integer()
  def route_prizes(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_prizes(solution_ref, route_idx)
  end

  @doc """
  Returns the visits (client indices) of a specific route.
  """
  @spec route_visits(t(), non_neg_integer()) :: [non_neg_integer()]
  def route_visits(%__MODULE__{solution_ref: solution_ref}, route_idx) do
    ExVrp.Native.solution_route_visits(solution_ref, route_idx)
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
    |> ExVrp.Native.solution_route_schedule(route_idx)
    |> Enum.map(&ExVrp.ScheduledVisit.from_tuple/1)
  end
end

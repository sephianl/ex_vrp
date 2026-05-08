defmodule ExVrp.Route do
  @moduledoc """
  Represents a single route in a VRP solution.

  A route is a sequence of client visits performed by one vehicle,
  starting and ending at designated depots.

  ## PyVRP Parity

  This module provides the same interface as PyVRP's Route class.
  Methods like `distance/1`, `duration/1`, etc. require the route
  to have a `solution_ref` and `route_idx` set. Use `Solution.route/2`
  or `Solution.routes/1` to get Route structs with proper context.

  ## Example

      {:ok, result} = Solver.solve(model)
      [route | _] = Solution.routes(result.best)

      # Now you can call route methods
      Route.distance(route)
      Route.feasible?(route)

  """

  alias ExVrp.Native

  @type t :: %__MODULE__{
          visits: [non_neg_integer()],
          vehicle_type: non_neg_integer(),
          start_depot: non_neg_integer(),
          end_depot: non_neg_integer(),
          trips: [ExVrp.Trip.t()],
          solution_ref: reference() | nil,
          route_idx: non_neg_integer() | nil
        }

  defstruct visits: [],
            vehicle_type: 0,
            start_depot: 0,
            end_depot: 0,
            trips: [],
            solution_ref: nil,
            route_idx: nil

  # ---------------------------------------------------------------------------
  # Feasibility
  # ---------------------------------------------------------------------------

  @doc """
  Checks if this route is feasible.
  """
  @spec feasible?(t()) :: boolean()
  def feasible?(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_is_feasible(ref, idx)
  end

  @doc """
  Checks if this route has excess load in any dimension.
  """
  @spec has_excess_load?(t()) :: boolean()
  def has_excess_load?(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_has_excess_load(ref, idx)
  end

  @doc """
  Checks if this route has excess distance.
  """
  @spec has_excess_distance?(t()) :: boolean()
  def has_excess_distance?(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_has_excess_distance(ref, idx)
  end

  @doc """
  Checks if this route has time warp.
  """
  @spec has_time_warp?(t()) :: boolean()
  def has_time_warp?(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_has_time_warp(ref, idx)
  end

  # ---------------------------------------------------------------------------
  # Load
  # ---------------------------------------------------------------------------

  @doc """
  Returns the total delivery load of this route per dimension.
  """
  @spec delivery(t()) :: [non_neg_integer()]
  def delivery(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_delivery(ref, idx)
  end

  @doc """
  Returns the total pickup load of this route per dimension.
  """
  @spec pickup(t()) :: [non_neg_integer()]
  def pickup(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_pickup(ref, idx)
  end

  @doc """
  Returns the excess load of this route per dimension.
  """
  @spec excess_load(t()) :: [non_neg_integer()]
  def excess_load(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_excess_load(ref, idx)
  end

  # ---------------------------------------------------------------------------
  # Distance/Duration
  # ---------------------------------------------------------------------------

  @doc """
  Returns the distance of this route.
  """
  @spec distance(t()) :: non_neg_integer()
  def distance(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_distance(ref, idx)
  end

  @doc """
  Returns the duration of this route.
  """
  @spec duration(t()) :: non_neg_integer()
  def duration(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_duration(ref, idx)
  end

  @doc """
  Returns the excess distance of this route.
  """
  @spec excess_distance(t()) :: non_neg_integer()
  def excess_distance(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_excess_distance(ref, idx)
  end

  @doc """
  Returns the time warp of this route.
  """
  @spec time_warp(t()) :: non_neg_integer()
  def time_warp(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_time_warp(ref, idx)
  end

  @doc """
  Returns the overtime of this route.
  """
  @spec overtime(t()) :: non_neg_integer()
  def overtime(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_overtime(ref, idx)
  end

  # ---------------------------------------------------------------------------
  # Costs
  # ---------------------------------------------------------------------------

  @doc """
  Returns the distance cost of this route.
  """
  @spec distance_cost(t()) :: non_neg_integer()
  def distance_cost(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_distance_cost(ref, idx)
  end

  @doc """
  Returns the duration cost of this route.
  """
  @spec duration_cost(t()) :: non_neg_integer()
  def duration_cost(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_duration_cost(ref, idx)
  end

  # ---------------------------------------------------------------------------
  # Timing
  # ---------------------------------------------------------------------------

  @doc """
  Returns the start time of this route.
  """
  @spec start_time(t()) :: non_neg_integer()
  def start_time(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_start_time(ref, idx)
  end

  @doc """
  Returns the end time of this route.
  """
  @spec end_time(t()) :: non_neg_integer()
  def end_time(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_end_time(ref, idx)
  end

  @doc """
  Returns the slack time of this route.
  """
  @spec slack(t()) :: non_neg_integer()
  def slack(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_slack(ref, idx)
  end

  @doc """
  Returns the service duration of this route.
  """
  @spec service_duration(t()) :: non_neg_integer()
  def service_duration(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_service_duration(ref, idx)
  end

  @doc """
  Returns the travel duration of this route.
  """
  @spec travel_duration(t()) :: non_neg_integer()
  def travel_duration(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_travel_duration(ref, idx)
  end

  @doc """
  Returns the wait duration of this route.
  """
  @spec wait_duration(t()) :: non_neg_integer()
  def wait_duration(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_wait_duration(ref, idx)
  end

  # ---------------------------------------------------------------------------
  # Accessors
  # ---------------------------------------------------------------------------

  @doc """
  Returns the visits (client indices) of this route.
  """
  @spec visits(t()) :: [non_neg_integer()]
  def visits(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_visits(ref, idx)
  end

  @doc """
  Returns the prizes collected on this route.
  """
  @spec prizes(t()) :: non_neg_integer()
  def prizes(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_prizes(ref, idx)
  end

  @doc """
  Returns the centroid of this route as {x, y}.
  """
  @spec centroid(t()) :: {float(), float()}
  def centroid(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_centroid(ref, idx)
  end

  @doc """
  Returns the vehicle type of this route.
  """
  @spec vehicle_type(t()) :: non_neg_integer()
  def vehicle_type(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_vehicle_type(ref, idx)
  end

  @doc """
  Returns the start depot of this route.
  """
  @spec start_depot(t()) :: non_neg_integer()
  def start_depot(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_start_depot(ref, idx)
  end

  @doc """
  Returns the end depot of this route.
  """
  @spec end_depot(t()) :: non_neg_integer()
  def end_depot(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_end_depot(ref, idx)
  end

  @doc """
  Returns the number of trips in this route.
  """
  @spec num_trips(t()) :: non_neg_integer()
  def num_trips(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_num_trips(ref, idx)
  end

  @doc """
  Returns the schedule of this route as a list of ScheduledVisit tuples.

  Each tuple contains: {location, trip, start_service, end_service, wait_duration, time_warp}
  """
  @spec schedule(t()) ::
          [
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
             non_neg_integer()}
          ]
  def schedule(%__MODULE__{solution_ref: ref, route_idx: idx}) do
    Native.solution_route_schedule(ref, idx)
  end

  # ---------------------------------------------------------------------------
  # Convenience (doesn't require solution_ref)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the number of clients visited in this route.

  This uses the local `visits` field and doesn't require a solution reference.
  """
  @spec num_clients(t()) :: non_neg_integer()
  def num_clients(%__MODULE__{visits: visits}) do
    length(visits)
  end
end

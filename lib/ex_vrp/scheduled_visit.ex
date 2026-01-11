defmodule ExVrp.ScheduledVisit do
  @moduledoc """
  Represents a scheduled visit in a route.

  A ScheduledVisit contains timing information about when a location is visited,
  including service start/end times, waiting time, and any time warp (lateness).

  ## Fields

  - `location` - The location index (depot or client) in ProblemData
  - `trip` - The trip index within the route (for multi-trip routes)
  - `start_service` - Time when service begins at this location
  - `end_service` - Time when service ends at this location
  - `wait_duration` - Time spent waiting before service can begin
  - `time_warp` - Amount of "time travel" needed (indicates infeasibility if > 0)

  ## Computed Properties

  - `service_duration` - Duration of service (end_service - start_service)

  ## Example

      # Get schedule for route 0
      schedule = Solution.route_schedule(solution, 0)

      # Iterate through visits
      Enum.each(schedule, fn visit ->
        IO.puts("Location \#{visit.location}: service \#{visit.start_service}-\#{visit.end_service}")
        if visit.time_warp > 0 do
          IO.puts("  WARNING: \#{visit.time_warp} time warp (late arrival)")
        end
      end)

  """

  @type t :: %__MODULE__{
          location: non_neg_integer(),
          trip: non_neg_integer(),
          start_service: non_neg_integer(),
          end_service: non_neg_integer(),
          wait_duration: non_neg_integer(),
          time_warp: non_neg_integer()
        }

  defstruct [
    :location,
    :trip,
    :start_service,
    :end_service,
    :wait_duration,
    :time_warp
  ]

  @doc """
  Creates a ScheduledVisit from a tuple returned by the NIF.

  The tuple format is: {location, trip, start_service, end_service, wait_duration, time_warp}
  """
  @spec from_tuple(
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer()}
        ) :: t()
  def from_tuple({location, trip, start_service, end_service, wait_duration, time_warp}) do
    %__MODULE__{
      location: location,
      trip: trip,
      start_service: start_service,
      end_service: end_service,
      wait_duration: wait_duration,
      time_warp: time_warp
    }
  end

  @doc """
  Returns the service duration (end_service - start_service).
  """
  @spec service_duration(t()) :: non_neg_integer()
  def service_duration(%__MODULE__{start_service: start, end_service: end_service}) do
    end_service - start
  end

  @doc """
  Returns true if this visit has time warp (late arrival).

  A visit with time warp indicates the vehicle arrived after the time window
  closed, making the route infeasible.
  """
  @spec has_time_warp?(t()) :: boolean()
  def has_time_warp?(%__MODULE__{time_warp: tw}), do: tw > 0

  @doc """
  Returns true if the vehicle had to wait at this location.
  """
  @spec has_wait?(t()) :: boolean()
  def has_wait?(%__MODULE__{wait_duration: wd}), do: wd > 0
end

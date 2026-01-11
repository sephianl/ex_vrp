defmodule ExVrp.DurationSegment do
  @moduledoc """
  Duration segments for tracking route timing during optimization.

  Duration segments can be efficiently concatenated, and track statistics
  about route and trip duration and time warp resulting from visiting clients
  in the concatenated order.

  This is a core data structure used by the local search operators to
  efficiently evaluate moves.

  ## Example

      ds1 = ExVrp.DurationSegment.new(5, 0, 0, 5, 0)
      ds2 = ExVrp.DurationSegment.new(0, 5, 3, 6, 0)
      merged = ExVrp.DurationSegment.merge(4, ds1, ds2)
      ExVrp.DurationSegment.time_warp(merged)

  """

  alias ExVrp.Native

  @type t :: reference()

  @int_max 9_223_372_036_854_775_807

  @doc """
  Creates a new duration segment.

  ## Parameters

  - `duration` - Total duration of current trip
  - `time_warp` - Total time warp on current trip
  - `start_early` - Earliest start time of current trip
  - `start_late` - Latest start time of current trip
  - `release_time` - Earliest moment to start this trip segment
  - `cum_duration` - Cumulative duration of other trips (default 0)
  - `cum_time_warp` - Cumulative time warp of other trips (default 0)
  - `prev_end_late` - Latest end time of previous trip (default INT_MAX)
  """
  @spec new(integer(), integer(), integer(), integer(), integer(), integer(), integer(), integer()) :: t()
  def new(
        duration,
        time_warp,
        start_early,
        start_late,
        release_time,
        cum_duration \\ 0,
        cum_time_warp \\ 0,
        prev_end_late \\ @int_max
      ) do
    Native.create_duration_segment_nif(
      duration,
      time_warp,
      start_early,
      start_late,
      release_time,
      cum_duration,
      cum_time_warp,
      prev_end_late
    )
  end

  @doc """
  Merges two duration segments with an edge duration.

  ## Parameters

  - `edge_duration` - Duration to travel between the segments
  - `first` - First duration segment
  - `second` - Second duration segment

  ## Returns

  A new merged duration segment.
  """
  @spec merge(integer(), t(), t()) :: t()
  def merge(edge_duration, first, second) do
    Native.duration_segment_merge_nif(edge_duration, first, second)
  end

  @doc """
  Returns the total duration of the whole segment.
  """
  @spec duration(t()) :: integer()
  def duration(segment) do
    Native.duration_segment_duration_nif(segment)
  end

  @doc """
  Returns the time warp on this whole segment.

  If `max_duration` is provided, any excess duration beyond it is also
  counted as time warp.
  """
  @spec time_warp(t(), integer()) :: integer()
  def time_warp(segment, max_duration \\ @int_max) do
    Native.duration_segment_time_warp_nif(segment, max_duration)
  end

  @doc """
  Returns the earliest start time for the current trip.
  """
  @spec start_early(t()) :: integer()
  def start_early(segment) do
    Native.duration_segment_start_early_nif(segment)
  end

  @doc """
  Returns the latest start time for the current trip.
  """
  @spec start_late(t()) :: integer()
  def start_late(segment) do
    Native.duration_segment_start_late_nif(segment)
  end

  @doc """
  Returns the earliest end time of the current trip.
  """
  @spec end_early(t()) :: integer()
  def end_early(segment) do
    Native.duration_segment_end_early_nif(segment)
  end

  @doc """
  Returns the latest end time of the current trip.
  """
  @spec end_late(t()) :: integer()
  def end_late(segment) do
    Native.duration_segment_end_late_nif(segment)
  end

  @doc """
  Returns the latest end time of the previous trip.
  """
  @spec prev_end_late(t()) :: integer()
  def prev_end_late(segment) do
    Native.duration_segment_prev_end_late_nif(segment)
  end

  @doc """
  Returns the release time of clients on the current trip.
  """
  @spec release_time(t()) :: integer()
  def release_time(segment) do
    Native.duration_segment_release_time_nif(segment)
  end

  @doc """
  Returns the slack in the route schedule.

  This is the amount of time by which the start of the current trip can
  be delayed without increasing the overall route duration.
  """
  @spec slack(t()) :: integer()
  def slack(segment) do
    Native.duration_segment_slack_nif(segment)
  end

  @doc """
  Finalises this segment at the back (end of segment).

  Returns a new segment where release times have been reset, and all
  other statistics have been suitably adjusted. This is useful with
  multiple trips because the finalised segment can be concatenated with
  segments of later trips.
  """
  @spec finalise_back(t()) :: t()
  def finalise_back(segment) do
    Native.duration_segment_finalise_back_nif(segment)
  end

  @doc """
  Finalises this segment at the front (start of segment).

  Returns a new segment where release times have been reset, and all
  other statistics have been suitably adjusted. This is useful with
  multiple trips because the finalised segment can be concatenated with
  segments of earlier trips.
  """
  @spec finalise_front(t()) :: t()
  def finalise_front(segment) do
    Native.duration_segment_finalise_front_nif(segment)
  end
end

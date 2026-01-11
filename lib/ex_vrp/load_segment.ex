defmodule ExVrp.LoadSegment do
  @moduledoc """
  Load segments for tracking capacity during optimization.

  Load segments track delivery and pickup loads, and can be efficiently
  concatenated to track capacity violations resulting from visiting clients
  in the concatenated order.

  This is a core data structure used by the local search operators to
  efficiently evaluate moves.

  ## Example

      ls1 = ExVrp.LoadSegment.new(10, 0, 10, 0)
      ls2 = ExVrp.LoadSegment.new(0, 5, 5, 0)
      merged = ExVrp.LoadSegment.merge(ls1, ls2)
      ExVrp.LoadSegment.excess_load(merged, 12)

  """

  alias ExVrp.Native

  @type t :: reference()

  @doc """
  Creates a new load segment.

  ## Parameters

  - `delivery` - Total delivery amount on this segment
  - `pickup` - Total pickup amount on this segment
  - `load` - Maximum load on this segment
  - `excess_load` - Cumulative excess load on this segment (default 0)
  """
  @spec new(integer(), integer(), integer(), integer()) :: t()
  def new(delivery, pickup, load, excess_load \\ 0) do
    Native.create_load_segment_nif(delivery, pickup, load, excess_load)
  end

  @doc """
  Merges two load segments.

  ## Parameters

  - `first` - First load segment
  - `second` - Second load segment

  ## Returns

  A new merged load segment.
  """
  @spec merge(t(), t()) :: t()
  def merge(first, second) do
    Native.load_segment_merge_nif(first, second)
  end

  @doc """
  Finalises the load on this segment.

  Returns a new segment where any excess load has been moved to the
  cumulative excess load field. This is useful with reloading, because
  the finalised segment can be concatenated with load segments of
  subsequent trips.

  ## Parameters

  - `segment` - The load segment to finalise
  - `capacity` - The capacity constraint
  """
  @spec finalise(t(), integer()) :: t()
  def finalise(segment, capacity) do
    Native.load_segment_finalise_nif(segment, capacity)
  end

  @doc """
  Returns the delivery amount, that is, the total amount of load delivered
  to clients on this segment.
  """
  @spec delivery(t()) :: integer()
  def delivery(segment) do
    Native.load_segment_delivery_nif(segment)
  end

  @doc """
  Returns the amount picked up from clients on this segment.
  """
  @spec pickup(t()) :: integer()
  def pickup(segment) do
    Native.load_segment_pickup_nif(segment)
  end

  @doc """
  Returns the maximum load encountered on this segment.
  """
  @spec load(t()) :: integer()
  def load(segment) do
    Native.load_segment_load_nif(segment)
  end

  @doc """
  Returns the load violation on this segment.

  ## Parameters

  - `segment` - The load segment
  - `capacity` - Segment capacity
  """
  @spec excess_load(t(), integer()) :: integer()
  def excess_load(segment, capacity) do
    Native.load_segment_excess_load_nif(segment, capacity)
  end
end

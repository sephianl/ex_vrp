defmodule ExVrp.VehicleType do
  @moduledoc """
  Represents a vehicle type in a VRP.

  Vehicle types define the characteristics of vehicles in the fleet,
  including capacity, costs, time windows, and depot assignments.
  """

  @type t :: %__MODULE__{
          num_available: pos_integer(),
          start_depot: non_neg_integer(),
          end_depot: non_neg_integer(),
          capacity: [non_neg_integer()],
          fixed_cost: non_neg_integer(),
          tw_early: non_neg_integer(),
          tw_late: non_neg_integer() | :infinity,
          shift_duration: non_neg_integer() | :infinity,
          max_distance: non_neg_integer() | :infinity,
          unit_distance_cost: non_neg_integer(),
          unit_duration_cost: non_neg_integer(),
          profile: non_neg_integer(),
          start_late: non_neg_integer(),
          max_overtime: non_neg_integer(),
          unit_overtime_cost: non_neg_integer(),
          reload_depots: [non_neg_integer()],
          max_reloads: non_neg_integer() | :infinity,
          initial_load: [non_neg_integer()],
          name: String.t(),
          forbidden_windows: [{non_neg_integer(), non_neg_integer()}]
        }

  @enforce_keys [:num_available, :capacity]
  defstruct [
    :num_available,
    :capacity,
    start_depot: 0,
    end_depot: 0,
    fixed_cost: 0,
    tw_early: 0,
    tw_late: :infinity,
    shift_duration: :infinity,
    max_distance: :infinity,
    unit_distance_cost: 1,
    unit_duration_cost: 0,
    profile: 0,
    start_late: 0,
    max_overtime: 0,
    unit_overtime_cost: 0,
    reload_depots: [],
    max_reloads: :infinity,
    initial_load: [],
    name: "",
    forbidden_windows: []
  ]

  @doc """
  Creates a new vehicle type.

  ## Required Options

  - `:num_available` - Number of vehicles of this type available
  - `:capacity` - List of capacity values per dimension

  ## Optional Options

  - `:time_windows` - List of `{start, end}` tuples representing operating windows
    (default: `[{0, :infinity}]`). Overlapping/adjacent windows are merged automatically.
    Example: `[{0, 500}, {600, 1000}]` becomes `tw_early: 0, tw_late: 1000,
    forbidden_windows: [{500, 600}]`.
  - `:start_depot` - Index of starting depot (default: `0`)
  - `:end_depot` - Index of ending depot (default: `0`)
  - `:fixed_cost` - Fixed cost for using this vehicle (default: `0`)
  - `:shift_duration` - Maximum shift duration (default: `:infinity`)
  - `:max_distance` - Maximum distance allowed (default: `:infinity`)
  - `:unit_distance_cost` - Cost per unit distance (default: `1`)
  - `:unit_duration_cost` - Cost per unit time (default: `0`)
  - `:profile` - Index of distance/duration matrix to use (default: `0`)
  - `:start_late` - Latest allowed start time (default: `0`)
  - `:max_overtime` - Maximum overtime allowed (default: `0`)
  - `:unit_overtime_cost` - Cost per unit of overtime (default: `0`)
  - `:reload_depots` - List of depot indices where vehicle can reload (default: `[]`)
  - `:max_reloads` - Maximum number of reloads per route (default: `:infinity`)
  - `:initial_load` - Initial load per dimension (default: `[]`)
  - `:name` - Vehicle type name (default: `""`)

  ## Raises

  - `ArgumentError` if `:time_windows` contains invalid tuples (start >= end or negative start)
  - `ArgumentError` if `:time_windows` is an empty list
  - `ArgumentError` if legacy options `:tw_early`, `:tw_late`, or `:forbidden_windows` are passed

  ## Examples

      iex> ExVrp.VehicleType.new(num_available: 3, capacity: [100, 50], time_windows: [{0, 28_800}])
      %ExVrp.VehicleType{num_available: 3, capacity: [100, 50], tw_early: 0, tw_late: 28_800, ...}

  """
  @spec new(keyword()) :: t()
  def new(opts) do
    validate_no_legacy_options!(opts)
    {time_windows, rest} = Keyword.pop(opts, :time_windows, [{0, :infinity}])

    validate_time_windows!(time_windows)

    windows =
      time_windows
      |> Enum.sort_by(fn {s, _end} -> s end)
      |> merge_windows()

    tw_early = elem(hd(windows), 0)
    tw_late = elem(List.last(windows), 1)

    forbidden =
      windows
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{_s, gap_start}, {gap_end, _e}] -> {gap_start, gap_end} end)

    struct!(__MODULE__, Keyword.merge(rest, tw_early: tw_early, tw_late: tw_late, forbidden_windows: forbidden))
  end

  defp validate_no_legacy_options!(opts) do
    legacy = [:tw_early, :tw_late, :forbidden_windows]

    found = Enum.filter(legacy, &Keyword.has_key?(opts, &1))

    if found != [] do
      raise ArgumentError,
            "#{inspect(found)} cannot be set directly, use :time_windows instead"
    end
  end

  defp validate_time_windows!(time_windows) do
    if time_windows == [] do
      raise ArgumentError, ":time_windows must be a non-empty list of {start, end} tuples"
    end

    Enum.each(time_windows, fn
      {s, :infinity} when is_integer(s) and s >= 0 ->
        :ok

      {s, e} when is_integer(s) and is_integer(e) and s >= 0 and e > s ->
        :ok

      other ->
        raise ArgumentError,
              "invalid time window: #{inspect(other)}, expected {start, end} where start >= 0 and end > start"
    end)
  end

  defp merge_windows([]), do: []

  defp merge_windows([first | rest]) do
    rest
    |> Enum.reduce([first], fn {s, e}, [{cs, ce} | tail] ->
      if lte(s, ce) do
        [{cs, max_end(ce, e)} | tail]
      else
        [{s, e}, {cs, ce} | tail]
      end
    end)
    |> Enum.reverse()
  end

  defp lte(_s, :infinity), do: true
  defp lte(s, ce), do: s <= ce

  defp max_end(:infinity, _other), do: :infinity
  defp max_end(_other, :infinity), do: :infinity
  defp max_end(a, b), do: max(a, b)
end

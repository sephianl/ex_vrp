defmodule ExVrp.VehicleType do
  @moduledoc """
  A class of interchangeable vehicles: how many there are, what they can carry,
  what they cost to run, and the limits they must respect.

  A vehicle type describes a *kind* of vehicle, not a single vehicle. Five
  identical vans are one vehicle type with `num_available: 5`. Add one to a
  model with `ExVrp.Model.add_vehicle_type/2`.

  Every limit is optional and defaults to `:infinity`, which constrains nothing.

  ## Routes and trips

  A **route** is one vehicle's whole working period: leave the start depot,
  visit clients, arrive at the end depot. A **trip** is one depot-to-depot leg
  of that route.

  Without `:reload_depots` a route is exactly one trip. With them, the vehicle
  can return to a depot mid-route to empty out or refill, and each such stop
  starts a new trip:

      depot ──trip 1──▶ reload ──trip 2──▶ reload ──trip 3──▶ depot
            clients            clients            clients

  Count them with `ExVrp.Route.num_trips/1`.

  ## What bounds what

  Each option bounds either the whole route or a single trip:

  | Option                   | Bounds          | Measures                               |
  | ------------------------ | --------------- | -------------------------------------- |
  | `:max_distance`          | the whole route | distance, summed over every trip       |
  | `:max_distance_per_trip` | one trip        | distance, reset at every reload        |
  | `:shift_duration`        | the whole route | elapsed time, idle included            |
  | `:max_duration`          | the whole route | elapsed time, idle included (hard cap) |
  | `:overtime_start`        | the whole route | clock time past the contracted end     |
  | `:max_reloads`           | the whole route | number of reloads, so trips - 1        |
  | `:capacity`              | one trip        | load carried, reset at every reload    |
  | `:time_windows`          | the whole route | when the vehicle may be on the road    |

  Without `:reload_depots` every row means the same thing.

  ## The two distance caps

  `:max_distance` bounds the route, summed over every trip — a vehicle that
  cannot refuel anywhere. `:max_distance_per_trip` bounds each trip and resets
  at every reload — a vehicle that refuels at the depot, so each trip starts
  with a full tank. They are independent: set either, both, or neither.

      iex> diesel = ExVrp.VehicleType.new(num_available: 1, capacity: [100], max_distance: 250_000)
      iex> electric = ExVrp.VehicleType.new(num_available: 1, capacity: [100], max_distance_per_trip: 250_000)
      iex> {diesel.max_distance, diesel.max_distance_per_trip}
      {250_000, :infinity}
      iex> {electric.max_distance, electric.max_distance_per_trip}
      {:infinity, 250_000}

  A vehicle that drives 140km, reloads, then drives another 120km breaches
  `max_distance: 250_000` by 10km, but satisfies
  `max_distance_per_trip: 250_000` — neither trip exceeded 250km on its own.

  Both violations are penalised at the same rate and reported together by
  `ExVrp.Route.excess_distance/1`, which does not say which cap was breached.
  A cap set too tight does not shorten routes: the solution is rejected and the
  vehicle drops out of the plan.

  ## Duration

  `:shift_duration` is the nominal shift, and the baseline for duration-based
  overtime. `:max_duration` is a hard ceiling that defaults to
  `:shift_duration`; raise it to allow overtime. `:overtime_start` marks a
  clock time after which work counts as overtime.

  All three measure *elapsed* time from route start to route end, so waiting
  for a customer's window to open counts against them like driving does. There
  is no per-trip duration cap: a second trip spends the same budget as the
  first. For time actually worked:

      ExVrp.Route.duration(route) - ExVrp.Route.wait_duration(route)

  ## Time windows

  `:time_windows` takes `{start, end}` tuples and is the only supported way to
  set when a vehicle may be on the road. `new/1` merges overlapping and
  adjacent windows, then derives `:tw_early`, `:tw_late`, and
  `:forbidden_windows` from the result. Setting those three directly raises —
  see `new/1`.

  All values are integers in your matrices' own units; the solver does not
  interpret them.
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
          max_distance_per_trip: non_neg_integer() | :infinity,
          unit_distance_cost: non_neg_integer(),
          unit_duration_cost: non_neg_integer(),
          profile: non_neg_integer(),
          start_late: non_neg_integer(),
          max_duration: non_neg_integer() | :infinity,
          unit_overtime_cost: non_neg_integer(),
          overtime_start: non_neg_integer() | :infinity,
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
    max_distance_per_trip: :infinity,
    unit_distance_cost: 1,
    unit_duration_cost: 0,
    profile: 0,
    start_late: 0,
    max_duration: nil,
    unit_overtime_cost: 0,
    overtime_start: :infinity,
    reload_depots: [],
    max_reloads: :infinity,
    initial_load: [],
    name: "",
    forbidden_windows: []
  ]

  @doc """
  Creates a new vehicle type.

  `ExVrp.Model.add_vehicle_type/2` calls this and adds the result to a model in
  one step.

  Whether a limit bounds the whole route or a single trip is in
  [What bounds what](#module-what-bounds-what).

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
  - `:shift_duration` - Nominal maximum duration of the **whole route**, and the
    baseline duration-based overtime is measured against (default: `:infinity`).
    Elapsed, not worked — see the scope table above
  - `:max_distance` - Maximum distance of the **whole route**, summed over every
    trip (default: `:infinity`). Reloading buys no extra range, so this models a
    vehicle that never refuels or recharges on the road
  - `:max_distance_per_trip` - Maximum distance of **one trip**, reset at every
    reload depot (default: `:infinity`). Models a vehicle that refuels or
    recharges each time it reloads, so every trip starts with a full tank.
    Independent of `:max_distance` — set either, both, or neither
  - `:unit_distance_cost` - Cost per unit distance (default: `1`)
  - `:unit_duration_cost` - Cost per unit time (default: `0`)
  - `:profile` - Index of distance/duration matrix to use (default: `0`)
  - `:start_late` - Latest allowed start time (default: `0`)
  - `:max_duration` - Hard maximum route duration, independent of `:shift_duration`
    but defaulting to it, i.e. a route may not run longer than its nominal shift
    unless you say otherwise. Measures **elapsed** time from route start to route
    end, so idle time between stops counts against it; it is not a cap on time
    worked. `new/1` resolves the default, so the struct always carries a concrete
    value
  - `:unit_overtime_cost` - Cost per unit of overtime (default: `0`)
  - `:overtime_start` - Clock time after which work counts as overtime, on the same
    axis as `:time_windows` (default: `:infinity`). When set, overtime is
    `max(0, route_end - overtime_start)` — time worked past the contracted end,
    regardless of how long the route itself took. When left at `:infinity`,
    overtime is `max(0, duration - shift_duration)` instead — which only ever
    exceeds zero if `:max_duration` was raised above `:shift_duration`.
  - `:reload_depots` - List of depot indices where vehicle can reload (default: `[]`)
  - `:max_reloads` - Maximum number of reloads per route (default: `:infinity`)
  - `:initial_load` - Initial load per dimension (default: `[]`)
  - `:name` - Vehicle type name (default: `""`)

  ## Raises

  - `ArgumentError` if `:time_windows` contains invalid tuples (start >= end or negative start)
  - `ArgumentError` if `:time_windows` is an empty list
  - `ArgumentError` if legacy options `:tw_early`, `:tw_late`, or `:forbidden_windows` are passed

  ## Examples

      iex> vt = ExVrp.VehicleType.new(num_available: 3, capacity: [100, 50], time_windows: [{0, 28_800}])
      iex> {vt.num_available, vt.capacity, vt.tw_early, vt.tw_late}
      {3, [100, 50], 0, 28_800}

  Gaps between windows become forbidden windows:

      iex> vt = ExVrp.VehicleType.new(num_available: 2, capacity: [100], time_windows: [{0, 500}, {600, 1000}])
      iex> {vt.tw_early, vt.tw_late, vt.forbidden_windows}
      {0, 1000, [{500, 600}]}

  Passing the derived fields directly is an error:

      iex> ExVrp.VehicleType.new(num_available: 1, capacity: [10], tw_early: 5)
      ** (ArgumentError) [:tw_early] cannot be set directly, use :time_windows instead

  """
  @spec new(keyword()) :: t()
  def new(opts) do
    validate_no_legacy_options!(opts)
    {time_windows, rest} = Keyword.pop(opts, :time_windows, [{0, :infinity}])

    validate_time_windows!(time_windows)

    {windows, {_first_unused, tw_late}} =
      time_windows
      |> Enum.sort_by(fn {s, _end} -> s end)
      |> merge_windows()

    [{tw_early, _early_end} | _rest] = windows

    forbidden =
      windows
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [{_s, gap_start}, {gap_end, _e}] -> {gap_start, gap_end} end)

    struct!(
      __MODULE__,
      Keyword.merge(rest,
        tw_early: tw_early,
        tw_late: tw_late,
        max_duration: resolve_max_duration(rest),
        forbidden_windows: forbidden
      )
    )
  end

  defp resolve_max_duration(opts) do
    defaults = %__MODULE__{num_available: 1, capacity: []}

    Keyword.get(opts, :max_duration) ||
      Keyword.get(opts, :shift_duration, defaults.shift_duration)
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

  defp merge_windows([]), do: {[], nil}

  defp merge_windows([first | rest]) do
    [last | _tail] =
      reversed =
      Enum.reduce(rest, [first], fn {s, e}, [{cs, ce} | tail] ->
        if lte(s, ce) do
          [{cs, max_end(ce, e)} | tail]
        else
          [{s, e}, {cs, ce} | tail]
        end
      end)

    {Enum.reverse(reversed), last}
  end

  defp lte(_s, :infinity), do: true
  defp lte(s, ce), do: s <= ce

  defp max_end(:infinity, _other), do: :infinity
  defp max_end(_other, :infinity), do: :infinity
  defp max_end(a, b), do: max(a, b)
end

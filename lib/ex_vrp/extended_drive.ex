defmodule ExVrp.ExtendedDrive do
  @moduledoc """
  Driving a route may do past a limit, at a price: every unit of the route's
  travel beyond `:start` costs `:unit_cost`, added to its
  `ExVrp.Route.duration_cost/1` like overtime. Set it as a vehicle type's
  `:extended_drive`; the vehicle type's `:max_drive` stays the hard cap above
  it.

  This models a limit the law lets a driver exceed now and then, such as
  EU 561/2006's 9-hour driving day that may run to 10 hours twice a week:
  the solver drives past `:start` only where that buys more than it costs,
  such as an optional client's prize. The last-resort pass that adds trips
  to multi-trip vehicles is the exception: it prices a trip by prize and
  distance alone, so it may place a client worth less than its extended
  driving.

  Travel past `:max_drive` is priced as well, on top of its time-warp
  penalty, so a start at or above a finite `:max_drive` could price only
  infeasible routes and `ExVrp.Model.validate/1` rejects it.

      iex> extended = ExVrp.ExtendedDrive.new(start: 540, unit_cost: 20)
      iex> {extended.start, extended.unit_cost}
      {540, 20}
  """

  import ExVrp.VehicleTypeCheck, only: [add_invalid: 4, non_negative_integer?: 1]

  alias ExVrp.Model
  alias ExVrp.VehicleType

  @enforce_keys [:start, :unit_cost]
  defstruct [:start, :unit_cost]

  @type t :: %__MODULE__{start: non_neg_integer(), unit_cost: non_neg_integer()}

  @doc "Creates an extended drive from `:start` and `:unit_cost`."
  @spec new(keyword()) :: t()
  def new(fields), do: struct!(__MODULE__, fields)

  @doc """
  Adds an error for each vehicle type whose `:extended_drive` is neither `nil`
  nor an `ExVrp.ExtendedDrive` with a non-negative integer start and unit cost,
  and for each whose start is at or past its finite `:max_drive`.
  """
  @spec validate([String.t()], Model.t()) :: [String.t()]
  def validate(errors, %Model{vehicle_types: vehicle_types}) do
    errors
    |> add_invalid(
      vehicle_types,
      &invalid?/1,
      "Vehicle type extended_drive must be nil or an ExVrp.ExtendedDrive with a non-negative integer start and unit_cost"
    )
    |> add_invalid(
      vehicle_types,
      &starts_at_or_past_max_drive?/1,
      "Vehicle type extended_drive start must be below max_drive, or it prices only infeasible routes"
    )
  end

  defp invalid?(%VehicleType{extended_drive: nil}), do: false

  defp invalid?(%VehicleType{extended_drive: %__MODULE__{start: start, unit_cost: unit_cost}}),
    do: not (non_negative_integer?(start) and non_negative_integer?(unit_cost))

  defp invalid?(%VehicleType{}), do: true

  defp starts_at_or_past_max_drive?(%VehicleType{extended_drive: %__MODULE__{start: start}, max_drive: max_drive})
       when is_integer(start) and is_integer(max_drive), do: start >= max_drive

  defp starts_at_or_past_max_drive?(%VehicleType{}), do: false
end

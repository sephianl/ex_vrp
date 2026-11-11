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
  such as an optional client's prize.

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
  nor an `ExVrp.ExtendedDrive` with a non-negative integer start and unit cost.
  """
  @spec validate([String.t()], Model.t()) :: [String.t()]
  def validate(errors, %Model{vehicle_types: vehicle_types}) do
    add_invalid(
      errors,
      vehicle_types,
      &invalid?/1,
      "Vehicle type extended_drive must be nil or an ExVrp.ExtendedDrive with a non-negative integer start and unit_cost"
    )
  end

  defp invalid?(%VehicleType{extended_drive: nil}), do: false

  defp invalid?(%VehicleType{extended_drive: %__MODULE__{start: start, unit_cost: unit_cost}}),
    do: not (non_negative_integer?(start) and non_negative_integer?(unit_cost))

  defp invalid?(%VehicleType{}), do: true
end

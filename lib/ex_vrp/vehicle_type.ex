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
          tw_late: non_neg_integer(),
          shift_duration: non_neg_integer(),
          max_distance: non_neg_integer(),
          unit_distance_cost: non_neg_integer(),
          unit_duration_cost: non_neg_integer(),
          start_late: non_neg_integer(),
          max_overtime: non_neg_integer(),
          name: String.t()
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
    start_late: 0,
    max_overtime: 0,
    name: ""
  ]

  @doc """
  Creates a new vehicle type.

  ## Required Options

  - `:num_available` - Number of vehicles of this type available
  - `:capacity` - List of capacity values per dimension

  ## Optional Options

  - `:start_depot` - Index of starting depot (default: `0`)
  - `:end_depot` - Index of ending depot (default: `0`)
  - `:fixed_cost` - Fixed cost for using this vehicle (default: `0`)
  - `:tw_early` - Earliest departure time (default: `0`)
  - `:tw_late` - Latest return time (default: `:infinity`)
  - `:shift_duration` - Maximum shift duration (default: `:infinity`)
  - `:max_distance` - Maximum distance allowed (default: `:infinity`)
  - `:unit_distance_cost` - Cost per unit distance (default: `1`)
  - `:unit_duration_cost` - Cost per unit time (default: `0`)
  - `:start_late` - Latest allowed start time (default: `0`)
  - `:max_overtime` - Maximum overtime allowed (default: `0`)
  - `:name` - Vehicle type name (default: `""`)

  ## Examples

      iex> ExVrp.VehicleType.new(num_available: 3, capacity: [100, 50])
      %ExVrp.VehicleType{num_available: 3, capacity: [100, 50], ...}

  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end
end

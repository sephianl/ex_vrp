defmodule ExVrp.Route do
  @moduledoc """
  Represents a single route in a VRP solution.

  A route is a sequence of client visits performed by one vehicle,
  starting and ending at designated depots.
  """

  @type t :: %__MODULE__{
          visits: [non_neg_integer()],
          vehicle_type: non_neg_integer(),
          start_depot: non_neg_integer(),
          end_depot: non_neg_integer(),
          trips: [ExVrp.Trip.t()]
        }

  defstruct visits: [],
            vehicle_type: 0,
            start_depot: 0,
            end_depot: 0,
            trips: []

  @doc """
  Returns the distance of this route.
  """
  @spec distance(t()) :: non_neg_integer()
  def distance(%__MODULE__{} = route) do
    ExVrp.Native.route_distance(route)
  end

  @doc """
  Returns the duration of this route.
  """
  @spec duration(t()) :: non_neg_integer()
  def duration(%__MODULE__{} = route) do
    ExVrp.Native.route_duration(route)
  end

  @doc """
  Returns the total delivery load of this route per dimension.
  """
  @spec delivery(t()) :: [non_neg_integer()]
  def delivery(%__MODULE__{} = route) do
    ExVrp.Native.route_delivery(route)
  end

  @doc """
  Returns the total pickup load of this route per dimension.
  """
  @spec pickup(t()) :: [non_neg_integer()]
  def pickup(%__MODULE__{} = route) do
    ExVrp.Native.route_pickup(route)
  end

  @doc """
  Checks if this route is feasible.
  """
  @spec feasible?(t()) :: boolean()
  def feasible?(%__MODULE__{} = route) do
    ExVrp.Native.route_is_feasible(route)
  end

  @doc """
  Returns the number of clients visited in this route.
  """
  @spec num_clients(t()) :: non_neg_integer()
  def num_clients(%__MODULE__{visits: visits}) do
    length(visits)
  end
end

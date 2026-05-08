defmodule ExVrp.Trip do
  @moduledoc """
  Represents a trip within a route.

  A trip is a continuous segment of visits between depot visits.
  In simple VRP, a route has exactly one trip. Multi-trip VRP
  allows vehicles to return to depots mid-route for reloading.
  """

  @type t :: %__MODULE__{
          visits: [non_neg_integer()],
          start_depot: non_neg_integer(),
          end_depot: non_neg_integer(),
          distance: non_neg_integer(),
          duration: non_neg_integer(),
          delivery: [non_neg_integer()],
          pickup: [non_neg_integer()]
        }

  defstruct visits: [],
            start_depot: 0,
            end_depot: 0,
            distance: 0,
            duration: 0,
            delivery: [],
            pickup: []
end

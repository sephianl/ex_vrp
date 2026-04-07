defmodule ExVrp.VehicleGroup do
  @moduledoc """
  Groups vehicle types that represent the same physical vehicle/driver.

  When routes are assigned to vehicle types in the same group, the solver
  enforces a minimum time gap between consecutive routes. This is useful
  for modeling multi-shift drivers where the same driver operates different
  shifts and needs reload/break time between them.

  ## Fields

  - `vehicle_type_indices` - Indices of vehicle types belonging to this group
  - `min_gap` - Minimum time gap required between consecutive routes
  """

  @type t :: %__MODULE__{
          vehicle_type_indices: [non_neg_integer()],
          min_gap: non_neg_integer()
        }

  defstruct vehicle_type_indices: [],
            min_gap: 0
end

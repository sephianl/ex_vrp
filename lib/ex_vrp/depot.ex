defmodule ExVrp.Depot do
  @moduledoc """
  Represents a depot (distribution center) in a VRP.

  Depots are locations where vehicles start and/or end their routes.
  """

  @type t :: %__MODULE__{
          x: number(),
          y: number(),
          tw_early: non_neg_integer(),
          tw_late: non_neg_integer(),
          name: String.t()
        }

  @enforce_keys [:x, :y]
  defstruct [
    :x,
    :y,
    tw_early: 0,
    tw_late: :infinity,
    name: ""
  ]

  @doc """
  Creates a new depot.

  ## Required Options

  - `:x` - X coordinate
  - `:y` - Y coordinate

  ## Optional Options

  - `:tw_early` - Earliest departure time (default: `0`)
  - `:tw_late` - Latest return time (default: `:infinity`)
  - `:name` - Depot name for identification (default: `""`)

  ## Examples

      iex> ExVrp.Depot.new(x: 0, y: 0)
      %ExVrp.Depot{x: 0, y: 0, ...}

  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end
end

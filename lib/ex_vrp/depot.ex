defmodule ExVrp.Depot do
  @moduledoc """
  Represents a depot (distribution center) in a VRP.

  Depots are locations where vehicles start and/or end their routes.
  """

  @type t :: %__MODULE__{
          tw_early: non_neg_integer(),
          tw_late: non_neg_integer(),
          service_duration: non_neg_integer(),
          reload_cost: non_neg_integer(),
          name: String.t()
        }

  defstruct tw_early: 0,
            tw_late: :infinity,
            service_duration: 0,
            reload_cost: 0,
            name: ""

  @doc """
  Creates a new depot.

  ## Required Options


  ## Optional Options

  - `:tw_early` - Earliest departure time (default: `0`)
  - `:tw_late` - Latest return time (default: `:infinity`)
  - `:service_duration` - Time required for loading/unloading at this depot during reloads (default: `0`)
  - `:reload_cost` - Cost incurred when a vehicle reloads at this depot (default: `0`)
  - `:name` - Depot name for identification (default: `""`)

  ## Examples

      iex> depot = ExVrp.Depot.new(tw_early: 0, tw_late: 3600)
      iex> {depot.tw_early, depot.tw_late}
      {0, 3600}

  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end
end

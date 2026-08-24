defmodule ExVrp.Client do
  @moduledoc """
  Represents a client (customer) location in a VRP.

  A client has coordinates, demand (delivery/pickup amounts), time windows,
  service duration, and optional grouping constraints.
  """

  @type t :: %__MODULE__{
          delivery: [non_neg_integer()],
          pickup: [non_neg_integer()],
          service_duration: non_neg_integer(),
          tw_early: non_neg_integer(),
          tw_late: non_neg_integer(),
          release_time: non_neg_integer(),
          prize: non_neg_integer(),
          required: boolean(),
          group: non_neg_integer() | nil,
          name: String.t()
        }

  defstruct delivery: [0],
            pickup: [0],
            service_duration: 0,
            tw_early: 0,
            tw_late: :infinity,
            release_time: 0,
            prize: 0,
            required: true,
            group: nil,
            name: ""

  @doc """
  Creates a new client.

  ## Required Options


  ## Optional Options

  - `:delivery` - List of delivery amounts per dimension (default: `[0]`)
  - `:pickup` - List of pickup amounts per dimension (default: `[0]`)
  - `:service_duration` - Time to service this client (default: `0`)
  - `:tw_early` - Earliest arrival time (default: `0`)
  - `:tw_late` - Latest arrival time (default: `:infinity`)
  - `:release_time` - Earliest time client becomes available (default: `0`)
  - `:prize` - Prize for visiting optional client (default: `0`)
  - `:required` - Whether client must be visited (default: `true`)
  - `:group` - Client group index for mutual exclusivity (default: `nil`)
  - `:name` - Client name for identification (default: `""`)

  ## Examples

      iex> client = ExVrp.Client.new(delivery: [10])
      iex> client.delivery
      [10]
      iex> {client.required, client.prize, client.tw_late}
      {true, 0, :infinity}

  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end
end

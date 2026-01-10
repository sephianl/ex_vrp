defmodule ExVrp.ClientGroup do
  @moduledoc """
  Represents a group of clients with mutual constraints.

  Client groups are used to express constraints like "visit at most one
  of these clients" (mutually exclusive) or other grouping requirements.
  """

  @type t :: %__MODULE__{
          clients: [non_neg_integer()],
          required: boolean(),
          name: String.t()
        }

  @enforce_keys [:clients]
  defstruct [
    :clients,
    required: false,
    name: ""
  ]

  @doc """
  Creates a new client group.

  ## Required Options

  - `:clients` - List of client indices in this group

  ## Optional Options

  - `:required` - Whether at least one client must be visited (default: `false`)
  - `:name` - Group name for identification (default: `""`)

  ## Examples

      iex> ExVrp.ClientGroup.new(clients: [1, 2, 3], required: true)
      %ExVrp.ClientGroup{clients: [1, 2, 3], required: true, ...}

  """
  @spec new(keyword()) :: t()
  def new(opts) do
    struct!(__MODULE__, opts)
  end
end

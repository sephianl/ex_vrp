defmodule ExVrp.ClientGroup do
  @moduledoc """
  Represents a group of clients with mutual constraints.

  Client groups are used to express constraints like "visit at most one
  of these clients" (mutually exclusive) or other grouping requirements.

  Groups are created empty and clients are added dynamically via
  `Model.add_client/2` with the `group:` option.

  ## Mutually Exclusive Groups

  When `required: false`, the group is automatically marked as mutually
  exclusive, meaning at most one client from the group can be visited.
  This matches PyVRP's semantics.

  ## Example

      {model, group} = Model.add_client_group(model, required: false)
      model = Model.add_client(model, x: 1, y: 1, group: group)
      model = Model.add_client(model, x: 2, y: 2, group: group)

  """

  @type t :: %__MODULE__{
          clients: [non_neg_integer()],
          required: boolean(),
          mutually_exclusive: boolean(),
          name: String.t()
        }

  defstruct clients: [],
            required: true,
            mutually_exclusive: false,
            name: ""

  @doc """
  Creates a new client group.

  Groups start empty - clients are added dynamically via `Model.add_client/2`.

  ## Options

  - `:required` - Whether at least one client must be visited (default: `true`)
  - `:mutually_exclusive` - Whether only one client can be visited (default: `not required`)
  - `:name` - Group name for identification (default: `""`)

  ## Examples

      iex> ExVrp.ClientGroup.new(required: false)
      %ExVrp.ClientGroup{clients: [], required: false, mutually_exclusive: true, name: ""}

      iex> ExVrp.ClientGroup.new(required: true, name: "priority")
      %ExVrp.ClientGroup{clients: [], required: true, mutually_exclusive: false, name: "priority"}

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    required = Keyword.get(opts, :required, true)
    mutually_exclusive = Keyword.get(opts, :mutually_exclusive, not required)

    %__MODULE__{
      clients: [],
      required: required,
      mutually_exclusive: mutually_exclusive,
      name: Keyword.get(opts, :name, "")
    }
  end

  @doc """
  Adds a client index to the group.

  This is called internally by `Model.add_client/2` when a group is specified.
  """
  @spec add_client(t(), non_neg_integer()) :: t()
  def add_client(%__MODULE__{clients: clients} = group, client_idx) do
    %{group | clients: clients ++ [client_idx]}
  end

  @doc """
  Clears all clients from the group.

  Used when depots are added after clients, requiring re-indexing.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = group) do
    %{group | clients: []}
  end
end

defmodule ExVrp.Shipment do
  @moduledoc """
  Goods collected at one client and dropped off at another.

  Both ends are ordinary clients, added with `ExVrp.Model.add_client/2`; each
  keeps its own time window, service duration, prize and `required` flag. The
  shipment only ties them together, with `ExVrp.Model.add_shipment/4`:

  - The delivery may only be visited after its pickup, on the same route and
    the same trip: a reload depot never sits between them. Breaks and rests
    may.
  - The pickup may be visited alone. Its goods then ride back to the depot,
    like a client's `pickup` amount does.
  - The `amount` takes up capacity from the pickup to the delivery (or to the
    trip's depot, without the delivery).

  A shipment is not the client `pickup` field. That one is a backhaul: goods
  collected at a client and returned to the depot, with no client to deliver
  them to.

  `pickup` and `delivery` are location indices (depots first, then clients),
  like a same-vehicle group's.
  """

  alias ExVrp.Client
  alias ExVrp.ClientGroup

  @type t :: %__MODULE__{
          pickup: non_neg_integer(),
          delivery: non_neg_integer(),
          amount: [non_neg_integer()]
        }

  @enforce_keys [:pickup, :delivery, :amount]
  defstruct [:pickup, :delivery, :amount]

  @doc """
  Prepends to `errors` a message for each malformed shipment in `model`, for
  `ExVrp.Model.validate/1`.
  """
  @spec validate([String.t()], ExVrp.Model.t()) :: [String.t()]
  def validate(errors, %{shipments: []}), do: errors

  def validate(errors, %{shipments: shipments} = model) do
    times_shipped = shipments |> Enum.flat_map(&[&1.pickup, &1.delivery]) |> Enum.frequencies()

    shipments
    |> Stream.with_index()
    |> Enum.flat_map(fn {shipment, idx} -> shipment_errors(shipment, idx, model, times_shipped) end)
    |> Enum.concat(errors)
  end

  defp shipment_errors(shipment, idx, model, times_shipped) do
    shipment
    |> clients(model)
    |> client_errors(shipment, idx, model, times_shipped)
  end

  defp client_errors({:ok, pickup, delivery}, shipment, idx, model, times_shipped) do
    Enum.concat([
      distinct_errors(shipment, idx),
      reuse_errors(shipment, idx, times_shipped),
      amount_errors(shipment.amount, idx, model.vehicle_types),
      required_errors(pickup, delivery, idx),
      client_kind_errors([pickup, delivery], idx, model.client_groups)
    ])
  end

  defp client_errors(:error, shipment, idx, _model, _times_shipped),
    do: ["Shipment #{idx} has invalid client index #{inspect({shipment.pickup, shipment.delivery})}"]

  defp clients(%__MODULE__{pickup: pickup, delivery: delivery}, %{depots: depots, clients: clients}) do
    num_depots = length(depots)
    client_range = num_depots..(num_depots + length(clients) - 1)//1

    if pickup in client_range and delivery in client_range do
      {:ok, Enum.at(clients, pickup - num_depots), Enum.at(clients, delivery - num_depots)}
    else
      :error
    end
  end

  defp distinct_errors(%__MODULE__{pickup: same, delivery: same}, idx),
    do: ["Shipment #{idx} picks up and delivers at the same client #{inspect(same)}"]

  defp distinct_errors(_shipment, _idx), do: []

  defp reuse_errors(shipment, idx, times_shipped) do
    [shipment.pickup, shipment.delivery]
    |> Enum.uniq()
    |> Enum.filter(&(Map.fetch!(times_shipped, &1) > 1))
    |> reuse_message(idx)
  end

  defp reuse_message([], _idx), do: []

  defp reuse_message(reused, idx), do: ["Shipment #{idx} shares clients #{inspect(reused)} with another shipment"]

  defp amount_errors(_amount, _idx, []), do: []

  defp amount_errors(amount, idx, [vehicle_type | _other_types]) do
    dims = length(vehicle_type.capacity)

    cond do
      length(amount) != dims -> ["Shipment #{idx} amount #{inspect(amount)} does not have #{dims} dimensions"]
      Enum.any?(amount, &(&1 < 0)) -> ["Shipment #{idx} amount #{inspect(amount)} must not be negative"]
      true -> []
    end
  end

  defp required_errors(%Client{required: false}, %Client{required: true}, idx),
    do: ["Shipment #{idx} has a required delivery but an optional pickup"]

  defp required_errors(_pickup, _delivery, _idx), do: []

  defp client_kind_errors(clients, idx, groups), do: Enum.flat_map(clients, &client_kind_error(&1, idx, groups))

  defp client_kind_error(%Client{is_break: true}, idx, _groups), do: ["Shipment #{idx} contains a break client"]

  defp client_kind_error(%Client{group: nil}, _idx, _groups), do: []

  defp client_kind_error(%Client{group: group}, idx, groups), do: group_error(Enum.at(groups, group), idx)

  defp group_error(%ClientGroup{mutually_exclusive: true}, idx),
    do: ["Shipment #{idx} contains a client in a mutually exclusive group"]

  defp group_error(_group, _idx), do: []
end

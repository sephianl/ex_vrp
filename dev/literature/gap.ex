defmodule ExVrp.Literature.Gap do
  @moduledoc "The relative gap of a cost to a best-known cost, and how the harness prints it."

  @spec of(number() | nil | :infinity, pos_integer()) :: float() | nil
  def of(cost, best_known) when is_number(cost), do: (cost - best_known) / best_known
  def of(_infeasible, _best_known), do: nil

  @spec format(float() | nil) :: String.t()
  def format(nil), do: "infeasible"
  def format(gap), do: :erlang.float_to_binary(gap * 100, decimals: 2) <> "%"
end

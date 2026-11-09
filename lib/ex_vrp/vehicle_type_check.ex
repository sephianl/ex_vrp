defmodule ExVrp.VehicleTypeCheck do
  @moduledoc """
  The plumbing `ExVrp.Breaks.validate/2` and `ExVrp.Rests.validate/2` share: one error per check,
  naming the vehicle types that fail it, and the limit predicates both apply.
  """

  alias ExVrp.VehicleType

  @doc "Prepends `message` with the indices of the vehicle types `invalid?` holds for, if any."
  @spec add_invalid([String.t()], [VehicleType.t()], (VehicleType.t() -> boolean()), String.t()) :: [String.t()]
  def add_invalid(errors, vehicle_types, invalid?, message) do
    vehicle_types
    |> Enum.with_index()
    |> Enum.filter(fn {vehicle_type, _idx} -> invalid?.(vehicle_type) end)
    |> Enum.map(fn {_vehicle_type, idx} -> idx end)
    |> prepend_message(errors, message)
  end

  defp prepend_message([], errors, _message), do: errors
  defp prepend_message(indices, errors, message), do: ["#{message} at indices #{inspect(indices)}" | errors]

  @doc "Whether `limit` is a positive integer or `:infinity`."
  @spec positive_or_infinity?(term()) :: boolean()
  def positive_or_infinity?(:infinity), do: true
  def positive_or_infinity?(limit), do: is_integer(limit) and limit > 0

  @doc "Whether `value` is a non-negative integer: a duration or a carry."
  @spec non_negative_integer?(term()) :: boolean()
  def non_negative_integer?(value), do: is_integer(value) and value >= 0

  @doc "Whether `carry` alone overruns a finite `limit`. An infinite or rejected limit is never overrun."
  @spec exceeds?(term(), term()) :: boolean()
  def exceeds?(carry, limit) when is_integer(limit) and limit > 0, do: carry > limit
  def exceeds?(_carry, _infinite_or_rejected_limit), do: false
end

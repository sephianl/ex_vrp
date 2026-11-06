defmodule ExVrp.Rests do
  @moduledoc """
  The model side of rests: validating a vehicle type's `ExVrp.DutyRule`, and
  how many rest clients `ExVrp.Breaks.append_pool/1` adds for it.

  A rest is a break client, so it rides in the same pool, after the breaks.
  Each vehicle gets as many rests as its `:shift_duration` can hold back to
  back, and one more: a period cut short by its driving, or a rest placed
  early, needs more of them than full periods would. A vehicle type without a
  shift takes the cap.
  """

  alias ExVrp.DutyRule
  alias ExVrp.Model
  alias ExVrp.VehicleType

  @max_rests_per_vehicle 14

  @doc """
  Adds an error for each vehicle type whose duty rule cannot work: a limit
  that is not positive, a limit without a rest duration or a break limit, or
  a carry that alone overruns its limit, which no rest can fix.
  """
  @spec validate([String.t()], Model.t()) :: [String.t()]
  def validate(errors, %Model{vehicle_types: vehicle_types}) do
    errors
    |> add_invalid(vehicle_types, &non_positive_limit?/1, non_positive_limit_message())
    |> add_invalid(vehicle_types, &half_configured?/1, half_configured_message())
    |> add_invalid(vehicle_types, &carry_overruns?/1, carry_overruns_message())
  end

  @doc "How many rest clients the pool holds for one vehicle of this type."
  @spec per_vehicle(VehicleType.t()) :: non_neg_integer()
  def per_vehicle(%VehicleType{duty_rule: rule, shift_duration: shift}),
    do: rests_for(DutyRule.limits?(rule), shift, rule)

  defp rests_for(false, _shift, _rule), do: 0
  defp rests_for(true, :infinity, _rule), do: @max_rests_per_vehicle
  defp rests_for(true, _shift, %DutyRule{rest_duration: rest}) when rest <= 0, do: @max_rests_per_vehicle

  defp rests_for(true, shift, %DutyRule{rest_duration: rest}), do: min(div(shift, rest) + 1, @max_rests_per_vehicle)

  defp add_invalid(errors, vehicle_types, invalid?, message) do
    vehicle_types
    |> Enum.with_index()
    |> Enum.filter(fn {%VehicleType{duty_rule: rule} = vehicle_type, _idx} ->
      rule != nil and invalid?.(vehicle_type)
    end)
    |> Enum.map(fn {_vehicle_type, idx} -> idx end)
    |> prepend_message(errors, message)
  end

  defp prepend_message([], errors, _message), do: errors
  defp prepend_message(indices, errors, message), do: ["#{message} at indices #{inspect(indices)}" | errors]

  defp non_positive_limit_message, do: "Vehicle type duty_rule max_duty and max_drive must be positive or :infinity"

  defp half_configured_message do
    "Vehicle type duty_rule with a limit needs a positive rest_duration and " <>
      "max_drive_between_breaks or max_work_between_breaks"
  end

  defp carry_overruns_message,
    do: "Vehicle type duty_rule duty_carry_in, drive_carry_in or duty_after_end exceeds its limit"

  defp non_positive_limit?(%VehicleType{duty_rule: %DutyRule{max_duty: duty, max_drive: drive}}),
    do: not positive_or_infinity?(duty) or not positive_or_infinity?(drive)

  defp positive_or_infinity?(:infinity), do: true
  defp positive_or_infinity?(limit), do: is_integer(limit) and limit > 0

  defp half_configured?(%VehicleType{duty_rule: %DutyRule{rest_duration: rest} = rule} = vehicle_type),
    do: DutyRule.limits?(rule) and not (rest > 0 and break_rule?(vehicle_type))

  defp break_rule?(%VehicleType{max_drive_between_breaks: :infinity, max_work_between_breaks: :infinity}), do: false
  defp break_rule?(%VehicleType{}), do: true

  defp carry_overruns?(%VehicleType{duty_rule: %DutyRule{} = rule}) do
    exceeds?(rule.duty_carry_in, rule.max_duty) or
      exceeds?(rule.duty_after_end, rule.max_duty) or
      exceeds?(rule.drive_carry_in, rule.max_drive)
  end

  defp exceeds?(carry, limit) when is_integer(limit) and limit > 0, do: carry > limit
  defp exceeds?(_carry, _infinite_or_rejected_limit), do: false
end

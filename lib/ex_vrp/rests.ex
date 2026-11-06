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

  import ExVrp.VehicleTypeCheck, only: [add_invalid: 4, positive_or_infinity?: 1, non_negative_integer?: 1, exceeds?: 2]

  alias ExVrp.DutyRule
  alias ExVrp.Model
  alias ExVrp.VehicleType

  @max_rests_per_vehicle 14

  @doc """
  Adds an error for each vehicle type whose duty rule cannot work: a rule
  that is not an `ExVrp.DutyRule`, a limit that is not positive, a rest
  duration or carry that is not a non-negative integer, a limit without a rest
  duration or a break limit, or a carry that alone overruns its limit, which
  no rest can fix.
  """
  @spec validate([String.t()], Model.t()) :: [String.t()]
  def validate(errors, %Model{vehicle_types: vehicle_types}) do
    errors
    |> add_invalid(vehicle_types, &not_a_duty_rule?/1, not_a_duty_rule_message())
    |> add_invalid(vehicle_types, with_rule(&non_positive_limit?/1), non_positive_limit_message())
    |> add_invalid(vehicle_types, with_rule(&non_integer_duration?/1), non_integer_duration_message())
    |> add_invalid(vehicle_types, with_rule(&half_configured?/1), half_configured_message())
    |> add_invalid(vehicle_types, with_rule(&carry_overruns?/1), carry_overruns_message())
  end

  @doc "How many rest clients the pool holds for one vehicle of this type."
  @spec per_vehicle(VehicleType.t()) :: non_neg_integer()
  def per_vehicle(%VehicleType{duty_rule: rule, shift_duration: shift}),
    do: rests_for(DutyRule.limits?(rule), shift, rule)

  defp rests_for(false, _shift, _rule), do: 0
  defp rests_for(true, :infinity, _rule), do: @max_rests_per_vehicle
  defp rests_for(true, _shift, %DutyRule{rest_duration: rest}) when rest <= 0, do: @max_rests_per_vehicle

  defp rests_for(true, shift, %DutyRule{rest_duration: rest}), do: min(div(shift, rest) + 1, @max_rests_per_vehicle)

  defp with_rule(invalid?), do: &(match?(%VehicleType{duty_rule: %DutyRule{}}, &1) and invalid?.(&1))

  defp not_a_duty_rule_message, do: "Vehicle type duty_rule must be nil or an ExVrp.DutyRule"

  defp non_positive_limit_message, do: "Vehicle type duty_rule max_duty and max_drive must be positive or :infinity"

  defp non_integer_duration_message do
    "Vehicle type duty_rule rest_duration, duty_carry_in, drive_carry_in and duty_after_end " <>
      "must be non-negative integers"
  end

  defp half_configured_message do
    "Vehicle type duty_rule with a limit needs a positive rest_duration and " <>
      "max_drive_between_breaks or max_work_between_breaks"
  end

  defp carry_overruns_message,
    do: "Vehicle type duty_rule duty_carry_in, drive_carry_in or duty_after_end exceeds its limit"

  defp not_a_duty_rule?(%VehicleType{duty_rule: nil}), do: false
  defp not_a_duty_rule?(%VehicleType{duty_rule: rule}), do: not is_struct(rule, DutyRule)

  defp non_positive_limit?(%VehicleType{duty_rule: %DutyRule{max_duty: duty, max_drive: drive}}),
    do: not positive_or_infinity?(duty) or not positive_or_infinity?(drive)

  defp non_integer_duration?(%VehicleType{duty_rule: %DutyRule{} = rule}) do
    not Enum.all?(
      [rule.rest_duration, rule.duty_carry_in, rule.drive_carry_in, rule.duty_after_end],
      &non_negative_integer?/1
    )
  end

  defp half_configured?(%VehicleType{duty_rule: %DutyRule{rest_duration: rest} = rule} = vehicle_type),
    do: DutyRule.limits?(rule) and not (rest > 0 and VehicleType.break_limits?(vehicle_type))

  defp carry_overruns?(%VehicleType{duty_rule: %DutyRule{} = rule}) do
    exceeds?(rule.duty_carry_in, rule.max_duty) or
      exceeds?(rule.duty_after_end, rule.max_duty) or
      exceeds?(rule.drive_carry_in, rule.max_drive)
  end
end

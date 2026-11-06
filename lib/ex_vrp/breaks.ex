defmodule ExVrp.Breaks do
  @moduledoc """
  The model side of breaks: validating a vehicle type's break fields, and the
  pool of break clients `ExVrp.Model.to_problem_data/1` hands the solver.

  Break clients go after every user client, so user indices are unchanged. The
  pool is shared: breaks are interchangeable, and each takes its duration from
  the route it lands on. Nothing reads their matrix rows, so zeros do; forbidden
  sets and vehicle locks are sparse and need nothing.

  Each vehicle gets enough breaks to cover its horizon, plus one: the drive
  clock's horizon is `:max_drive` (else `:shift_duration`), the work clock's is
  `:shift_duration`. Under a duty rule the rests reset both clocks, so neither
  needs more than enough for each duty period it can split the route into,
  plus one each: a period's drive is at most the rule's `:max_drive` (else
  `:max_duty`), its work `:max_duty`. A clock bounded by neither takes the cap
  per period. Rest clients (`ExVrp.Rests`) follow the breaks.
  """

  import ExVrp.VehicleTypeCheck, only: [add_invalid: 4, positive_or_infinity?: 1, exceeds?: 2]

  alias ExVrp.Client
  alias ExVrp.DutyRule
  alias ExVrp.Matrix
  alias ExVrp.Model
  alias ExVrp.Rests
  alias ExVrp.VehicleType

  @max_breaks_per_vehicle 12

  @doc """
  Adds an error for each vehicle type whose break fields cannot work: a limit
  that is not positive, a break duration without a limit or a limit without
  one, or a carry that alone overruns its limit, which no break can fix.
  """
  @spec validate([String.t()], Model.t()) :: [String.t()]
  def validate(errors, %Model{vehicle_types: vehicle_types}) do
    errors
    |> add_invalid(vehicle_types, &non_positive_limit?/1, non_positive_limit_message())
    |> add_invalid(vehicle_types, &mismatched_duration?/1, mismatched_duration_message())
    |> add_invalid(vehicle_types, &carry_overruns?/1, carry_overruns_message())
  end

  @doc """
  The model with its pool of break and rest clients appended, or unchanged when no vehicle type
  has limits.
  """
  @spec append_pool(Model.t()) :: Model.t()
  def append_pool(%Model{vehicle_types: vehicle_types} = model) do
    num_breaks = Enum.sum_by(vehicle_types, &(&1.num_available * breaks_per_vehicle(&1)))
    num_rests = Enum.sum_by(vehicle_types, &(&1.num_available * Rests.per_vehicle(&1)))

    append_pauses(model, num_breaks, num_rests)
  end

  defp mismatched_duration_message do
    "Vehicle type break_duration must be positive exactly when max_drive_between_breaks or " <>
      "max_work_between_breaks is set"
  end

  defp carry_overruns_message do
    "Vehicle type drive_carry_in, work_carry_in or work_after_end exceeds its limit between breaks"
  end

  defp non_positive_limit_message do
    "Vehicle type max_drive_between_breaks and max_work_between_breaks must be positive or :infinity"
  end

  defp non_positive_limit?(%VehicleType{} = vehicle_type) do
    not positive_or_infinity?(vehicle_type.max_drive_between_breaks) or
      not positive_or_infinity?(vehicle_type.max_work_between_breaks)
  end

  defp mismatched_duration?(%VehicleType{break_duration: duration} = vehicle_type) do
    VehicleType.break_limits?(vehicle_type) != duration > 0
  end

  defp carry_overruns?(%VehicleType{} = vehicle_type) do
    exceeds?(vehicle_type.drive_carry_in, vehicle_type.max_drive_between_breaks) or
      exceeds?(vehicle_type.work_carry_in, vehicle_type.max_work_between_breaks) or
      exceeds?(vehicle_type.work_after_end, vehicle_type.max_work_between_breaks)
  end

  defp append_pauses(model, 0, 0), do: model

  defp append_pauses(model, num_breaks, num_rests) do
    zeros = List.duplicate(0, length(hd(model.vehicle_types).capacity))
    break = Client.new(delivery: zeros, pickup: zeros, required: false, is_break: true)
    rest = %{break | is_rest: true}
    pool_size = num_breaks + num_rests

    %{
      model
      | clients: model.clients ++ List.duplicate(break, num_breaks) ++ List.duplicate(rest, num_rests),
        distance_matrices: Enum.map(model.distance_matrices, &Matrix.pad(&1, pool_size)),
        duration_matrices: Enum.map(model.duration_matrices, &Matrix.pad(&1, pool_size)),
        profiles: Enum.map(model.profiles, &pad_override_row(&1, pool_size)),
        penalties: Enum.map(model.penalties, &(&1 ++ List.duplicate(0, pool_size)))
    }
  end

  defp pad_override_row(%{override_row: {row, distances, durations}} = profile, pool_size),
    do: %{profile | override_row: {row, Matrix.pad_row(distances, pool_size), Matrix.pad_row(durations, pool_size)}}

  defp pad_override_row(profile, _pool_size), do: profile

  defp breaks_per_vehicle(%VehicleType{duty_rule: rule} = vehicle_type) do
    num_periods = Rests.per_vehicle(vehicle_type) + 1

    [
      {vehicle_type.max_drive_between_breaks, drive_horizon(vehicle_type), drive_period(rule)},
      {vehicle_type.max_work_between_breaks, vehicle_type.shift_duration, work_period(rule)}
    ]
    |> Enum.reject(fn {limit, _horizon, _period} -> limit == :infinity end)
    |> Enum.map(fn {limit, horizon, period} ->
      breaks_within_horizon(horizon, limit, num_periods * breaks_per_period(period, limit))
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp drive_horizon(%VehicleType{max_drive: :infinity, shift_duration: shift}), do: shift
  defp drive_horizon(%VehicleType{max_drive: max_drive}), do: max_drive

  defp drive_period(%DutyRule{max_drive: :infinity, max_duty: max_duty}), do: max_duty
  defp drive_period(%DutyRule{max_drive: max_drive}), do: max_drive
  defp drive_period(nil), do: :infinity

  defp work_period(%DutyRule{max_duty: max_duty}), do: max_duty
  defp work_period(nil), do: :infinity

  defp breaks_within_horizon(:infinity, _limit, period_bound), do: period_bound
  defp breaks_within_horizon(horizon, limit, period_bound), do: min(breaks_within(horizon, limit), period_bound)

  defp breaks_per_period(:infinity, _limit), do: @max_breaks_per_vehicle
  defp breaks_per_period(period, limit), do: breaks_within(period, limit)

  defp breaks_within(horizon, limit), do: div(horizon + limit - 1, limit) + 1
end

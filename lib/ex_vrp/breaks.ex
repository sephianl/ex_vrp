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
  `:shift_duration`, and a vehicle type without one takes the cap.
  """

  alias ExVrp.Client
  alias ExVrp.Model
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

  @doc "The model with its pool of break clients appended, or unchanged when no vehicle type has limits."
  @spec append_pool(Model.t()) :: Model.t()
  def append_pool(%Model{vehicle_types: vehicle_types} = model) do
    vehicle_types
    |> Enum.sum_by(&(&1.num_available * breaks_per_vehicle(&1)))
    |> append_breaks(model)
  end

  defp add_invalid(errors, vehicle_types, invalid?, message) do
    vehicle_types
    |> Enum.with_index()
    |> Enum.filter(fn {vehicle_type, _idx} -> invalid?.(vehicle_type) end)
    |> Enum.map(fn {_vehicle_type, idx} -> idx end)
    |> prepend_message(errors, message)
  end

  defp prepend_message([], errors, _message), do: errors
  defp prepend_message(indices, errors, message), do: ["#{message} at indices #{inspect(indices)}" | errors]

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

  defp positive_or_infinity?(:infinity), do: true
  defp positive_or_infinity?(limit), do: is_integer(limit) and limit > 0

  defp mismatched_duration?(%VehicleType{break_duration: duration} = vehicle_type) do
    has_limit?(vehicle_type) != duration > 0
  end

  defp has_limit?(%VehicleType{max_drive_between_breaks: :infinity, max_work_between_breaks: :infinity}), do: false
  defp has_limit?(%VehicleType{}), do: true

  defp carry_overruns?(%VehicleType{} = vehicle_type) do
    exceeds?(vehicle_type.drive_carry_in, vehicle_type.max_drive_between_breaks) or
      exceeds?(vehicle_type.work_carry_in, vehicle_type.max_work_between_breaks) or
      exceeds?(vehicle_type.work_after_end, vehicle_type.max_work_between_breaks)
  end

  defp exceeds?(carry, limit) when is_integer(limit) and limit > 0, do: carry > limit
  defp exceeds?(_carry, _infinite_or_rejected_limit), do: false

  defp append_breaks(0, model), do: model

  defp append_breaks(pool_size, model) do
    zeros = List.duplicate(0, length(hd(model.vehicle_types).capacity))
    break = Client.new(delivery: zeros, pickup: zeros, required: false, is_break: true)

    %{
      model
      | clients: model.clients ++ List.duplicate(break, pool_size),
        distance_matrices: Enum.map(model.distance_matrices, &pad_matrix(&1, pool_size)),
        duration_matrices: Enum.map(model.duration_matrices, &pad_matrix(&1, pool_size)),
        penalties: Enum.map(model.penalties, &(&1 ++ List.duplicate(0, pool_size)))
    }
  end

  defp pad_matrix(matrix, pool_size) do
    padding = List.duplicate(0, pool_size)
    zero_row = List.duplicate(0, length(matrix) + pool_size)

    Enum.map(matrix, &(&1 ++ padding)) ++ List.duplicate(zero_row, pool_size)
  end

  defp breaks_per_vehicle(%VehicleType{} = vehicle_type) do
    [
      {vehicle_type.max_drive_between_breaks, drive_horizon(vehicle_type)},
      {vehicle_type.max_work_between_breaks, vehicle_type.shift_duration}
    ]
    |> Enum.reject(fn {limit, _horizon} -> limit == :infinity end)
    |> Enum.map(fn {limit, horizon} -> breaks_within(horizon, limit) end)
    |> Enum.max(fn -> 0 end)
  end

  defp drive_horizon(%VehicleType{max_drive: :infinity, shift_duration: shift}), do: shift
  defp drive_horizon(%VehicleType{max_drive: max_drive}), do: max_drive

  defp breaks_within(:infinity, _limit), do: @max_breaks_per_vehicle
  defp breaks_within(horizon, limit), do: min(div(horizon + limit - 1, limit) + 1, @max_breaks_per_vehicle)
end

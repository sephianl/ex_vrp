defmodule ExVrp.ABBenchmark.SpeedMeasurementError do
  @moduledoc """
  Raised when `ExVrp.ABBenchmark.Speed` cannot count an instance's instructions,
  so the speed check fails loudly instead of reporting a speed it never measured.
  """
  defexception [:instance, :reason]

  @impl Exception
  def message(%__MODULE__{instance: instance, reason: reason}), do: "could not measure #{instance}'s speed: #{reason}"
end

defmodule ExVrp.SolveError do
  @moduledoc """
  Raised by `ExVrp.solve!/2` when `ExVrp.solve/2` returns `{:error, reason}`.

  That happens when the model cannot be solved at all, not when no feasible
  solution turns up: an infeasible model still returns `{:ok, result}`, with
  `result.best` infeasible and its `cost` `:infinity`. In practice `reason` is
  the list of messages `ExVrp.Model.validate/1` rejected the model with, and the
  message lists one per line.
  """

  defexception [:reason]

  @impl Exception
  def message(%{reason: [message | _rest] = messages}) when is_binary(message) do
    IO.iodata_to_binary(["Solver failed:\n", Enum.map_intersperse(messages, "\n", &["  - ", &1])])
  end

  def message(%{reason: reason}) when is_binary(reason) do
    "Solver failed: #{reason}"
  end

  def message(%{reason: reason}) do
    "Solver failed: #{inspect(reason)}"
  end
end

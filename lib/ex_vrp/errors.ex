defmodule ExVrp.NotImplementedError do
  @moduledoc """
  Raised when a NIF function is not yet implemented.

  This error is temporary during development and will be removed
  once all C++ bindings are complete.
  """

  defexception [:function]

  @impl true
  def message(%{function: function}) do
    "NIF function #{function} is not yet implemented. " <>
      "See README.md for implementation status."
  end
end

defmodule ExVrp.SolveError do
  @moduledoc """
  Raised when the solver fails to find a solution.
  """

  defexception [:reason]

  @impl true
  def message(%{reason: reason}) when is_binary(reason) do
    "Solver failed: #{reason}"
  end

  def message(%{reason: reason}) do
    "Solver failed: #{inspect(reason)}"
  end
end

defmodule ExVrp.ValidationError do
  @moduledoc """
  Raised when model validation fails.
  """

  defexception [:errors]

  @impl true
  def message(%{errors: errors}) do
    "Model validation failed:\n" <>
      Enum.map_join(errors, "\n", &"  - #{&1}")
  end
end

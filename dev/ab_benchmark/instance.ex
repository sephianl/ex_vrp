defmodule ExVrp.ABBenchmark.Instance do
  @moduledoc """
  A loaded corpus entry: its model, and the penalty bounds it has to be solved under.
  `ExVrp.ABBenchmark.Loader` explains where the bounds come from.
  """

  alias ExVrp.PenaltyManager.Params

  @type t :: %__MODULE__{model: ExVrp.Model.t(), penalty_params: Params.t()}
  @enforce_keys [:model]
  defstruct [:model, penalty_params: %Params{}]
end

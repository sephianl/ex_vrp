defmodule ExVrp.ABBenchmark.Instance do
  @moduledoc """
  A loaded corpus entry: its model, the penalty bounds it has to be solved under, and the
  routes a solve starts from when the capture had them. `ExVrp.ABBenchmark.Loader` explains
  where the bounds and routes come from.
  """

  alias ExVrp.PenaltyManager.Params

  @type t :: %__MODULE__{
          model: ExVrp.Model.t(),
          penalty_params: Params.t(),
          initial_routes: [ExVrp.Solution.warm_start_visits()] | nil
        }
  @enforce_keys [:model]
  defstruct [:model, penalty_params: %Params{}, initial_routes: nil]
end

defmodule ExVrp.SameVehicleGroupPricingTest do
  @moduledoc """
  What a same-vehicle group costs the search, as opposed to what it forbids.

  A split group makes the whole solution infeasible through `isGroupFeas_`, so
  nothing downstream can accept it. The search therefore has to be able to see
  the violation and price it against the prizes it is trading away — the same
  bargain load, time warp and excess distance already get.
  """

  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.PenaltyManager
  alias ExVrp.Solution
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  @prize 3_333_300_000

  # The claim is about what the search reliably does, not what one lucky seed did, so it is asserted
  # over a spread of them.
  @seeds 1..10

  @penalty_params %PenaltyManager.Params{
    min_penalty: 2_222.2,
    max_penalty: 333_330_000_000.0
  }

  defp model_with_unsatisfiable_group do
    coords = for i <- 0..8, do: {i, 0}

    Model.new()
    |> Model.add_depot([])
    |> then(fn model ->
      Enum.reduce(1..8, model, fn i, acc ->
        Model.add_client(acc,
          delivery: [1],
          prize: @prize,
          required: false,
          tw_early: window_start(i),
          tw_late: window_end(i)
        )
      end)
    end)
    |> Model.add_vehicle_type(
      num_available: 1,
      capacity: [100],
      name: "early",
      time_windows: [{0, 600}]
    )
    |> Model.add_vehicle_type(
      num_available: 1,
      capacity: [100],
      name: "late",
      time_windows: [{1_000, 2_000}]
    )
    |> Model.set_euclidean_matrices(coords)
    |> Model.add_same_vehicle_group([0, 4], name: "keys")
  end

  defp window_start(5), do: 1_200
  defp window_start(_client), do: 0

  defp window_end(1), do: 300
  defp window_end(5), do: 1_900
  defp window_end(_client), do: 2_000

  defp solved(model, seed) do
    {:ok, %{best: best}} =
      ExVrp.solve(model,
        stop: StoppingCriteria.max_iterations(2_000),
        seed: seed,
        num_starts: 1,
        penalty_params: @penalty_params
      )

    best
  end

  test "an unsatisfiable group drops one of its members rather than emptying the plan" do
    model = model_with_unsatisfiable_group()

    outcomes = for seed <- @seeds, do: solved(model, seed)

    assert Enum.all?(outcomes, &Solution.feasible?/1)
    assert Enum.min(Enum.map(outcomes, &Solution.num_clients/1)) >= 7
  end
end

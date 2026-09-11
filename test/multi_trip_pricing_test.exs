defmodule ExVrp.MultiTripPricingTest do
  @moduledoc """
  Tests that opening a new trip is priced in the objective's own currency.

  The multi-trip insertion heuristics used to estimate a new trip by hand, as
  raw distance units plus reload cost minus the prize, and then compare that
  against a properly evaluated alternative in cost units. Whenever distance
  costs more than one unit the estimate understated, so opening a new trip
  looked cheap however expensive it really was.

  `Solution.insert/4`'s new-trip branch now prices through `insertTripCost`,
  because there it is compared against an exactly-priced plain insertion and the
  two have to be in the same currency.

  `LocalSearch::improveWithMultiTrip` deliberately still estimates. Its
  threshold is a bare zero rather than a rival move, so the optimism is what
  makes it place clients the main search gave up on; pricing it exactly cost a
  fifth of the coverage on the production instance. See the comment there.

  These tests pin the primitive, which is where the defect is observable. They
  are deliberately not solver-level: every operator that runs after a mis-priced
  insertion prices exactly, so the search removes the client or the reload depot
  again, and the ILS accepts on exact penalised cost regardless.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  # 0 = depot, 1 and 2 = clients near it, 3 = a client 30 units out and back.
  @matrix [
    [0, 10, 20, 30],
    [10, 0, 15, 25],
    [20, 15, 0, 35],
    [30, 25, 35, 0]
  ]

  # Appending a reload depot and client 3 after the route [1, 2] adds the
  # edges 2 -> 0, 0 -> 3, 3 -> 0 and drops 2 -> 0, so 30 + 30 = 60 of distance.
  @trip_distance 60

  defp model(vehicle_opts, client_opts) do
    Model.new()
    |> Model.add_depot(tw_early: 0, tw_late: 45_000)
    |> Model.add_client(delivery: [1], tw_early: 0, tw_late: 45_000, service_duration: 10)
    |> Model.add_client(delivery: [1], tw_early: 0, tw_late: 45_000, service_duration: 10)
    |> Model.add_client(
      Keyword.merge(
        [delivery: [1], tw_early: 0, tw_late: 45_000, service_duration: 10],
        client_opts
      )
    )
    |> Model.add_vehicle_type(
      Keyword.merge(
        [
          num_available: 1,
          capacity: [10],
          time_windows: [{0, 45_000}],
          reload_depots: [0],
          max_reloads: 2
        ],
        vehicle_opts
      )
    )
    |> Model.set_distance_matrices([@matrix])
    |> Model.set_duration_matrices([@matrix])
  end

  describe "insert_trip_cost" do
    defp trip_cost(unit_distance_cost), do: price_trip(unit_distance_cost, 0, :end_of_route)

    defp price_trip(unit_distance_cost, depot, idx) do
      {:ok, problem_data} =
        Model.to_problem_data(model([unit_distance_cost: unit_distance_cost], []))

      {:ok, cost_evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [1.0],
          tw_penalty: 1.0,
          dist_penalty: 0.0
        )

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      node = Native.create_search_node_nif(problem_data, 3)

      Native.insert_trip_cost_nif(node, route, depot, trip_idx(idx, route), problem_data, cost_evaluator)
    end

    defp trip_idx(:end_of_route, route), do: Native.search_route_size_nif(route) - 1
    defp trip_idx(idx, _route), do: idx

    test "charges the vehicle's distance cost, not raw distance units" do
      assert trip_cost(1) == @trip_distance
      assert trip_cost(100) == 100 * @trip_distance
    end

    test "scales with unit_distance_cost" do
      # The defect this guards: the old hand-rolled estimate was the raw trip
      # distance, so it returned the same number whatever a unit of distance
      # actually cost, and undercut every correctly evaluated alternative.
      assert trip_cost(100) - trip_cost(1) == 99 * @trip_distance
    end

    test "raises rather than reinterpreting a client as a depot" do
      assert_raise ArgumentError, ~r/depot is out of range/, fn ->
        price_trip(1, 99, :end_of_route)
      end
    end

    test "raises rather than walking off either end of the route" do
      assert_raise ArgumentError, ~r/idx must be in/, fn -> price_trip(1, 0, 0) end
      assert_raise ArgumentError, ~r/idx must be in/, fn -> price_trip(1, 0, 999) end
    end
  end

  describe "the search" do
    test "still opens a trip when capacity requires one" do
      # Guards the other direction: pricing trips honestly must not stop the
      # search creating them when they are the only way to serve the clients.
      model =
        Model.new()
        |> Model.add_depot(tw_early: 0, tw_late: 45_000)
        |> Model.add_client(delivery: [80], tw_early: 0, tw_late: 45_000)
        |> Model.add_client(delivery: [80], tw_early: 0, tw_late: 45_000)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 45_000}],
          reload_depots: [0],
          max_reloads: 5
        )
        |> Model.set_distance_matrices([[[0, 10, 20], [10, 0, 15], [20, 15, 0]]])
        |> Model.set_duration_matrices([[[0, 10, 20], [10, 0, 15], [20, 15, 0]]])

      [route] = Solution.routes(solve(model))

      assert Route.num_trips(route) == 2
    end
  end

  defp solve(model) do
    {:ok, %{best: best}} =
      ExVrp.solve(model,
        stop: StoppingCriteria.max_iterations(2_000),
        seed: 42,
        num_starts: 1
      )

    best
  end
end

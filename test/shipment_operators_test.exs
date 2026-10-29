defmodule ExVrp.ShipmentOperatorsTest do
  @moduledoc """
  Each search operator on its own, from random starts on instances with
  shipments, reloads and optional halves. An operator that moved a pickup away
  from its delivery would make the unloaded solution's trip validation raise,
  so every run returning a solution whose deliveries follow their pickups is
  the gate working.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  @moduletag :nif_required

  @node_operators [
    :exchange10,
    :exchange20,
    :exchange30,
    :exchange11,
    :exchange21,
    :exchange22,
    :exchange31,
    :exchange32,
    :exchange33,
    :swap_tails,
    :relocate_with_depot,
    :relocate_shipment
  ]

  defp model(seed) do
    :rand.seed(:exsss, {seed, 3, 5})

    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_vehicle_type(num_available: 3, capacity: [25], reload_depots: [0], max_reloads: 2)

    model =
      Enum.reduce(0..7, model, fn pair, acc ->
        optional = rem(pair, 3) == 0

        acc
        |> Model.add_client(half(optional))
        |> Model.add_client(half(optional))
        |> Model.add_client(delivery: [Enum.random(0..8)])
        |> Model.add_shipment(3 * pair, 3 * pair + 1, [Enum.random(1..12)])
      end)

    Model.set_euclidean_matrices(model, for(_loc <- 0..24, do: {Enum.random(0..100), Enum.random(0..100)}))
  end

  defp half(true), do: [required: false, prize: 300]
  defp half(false), do: []

  defp assert_precedence(ref, model) do
    trips = ref |> Native.solution_trips() |> Enum.flat_map(& &1) |> Enum.map(& &1.clients)

    for %{pickup: pickup, delivery: delivery} <- model.shipments, trip <- trips, delivery in trip do
      assert pickup in trip
      assert Enum.find_index(trip, &(&1 == pickup)) < Enum.find_index(trip, &(&1 == delivery))
    end
  end

  test "no operator splits a shipment" do
    {:ok, cost_evaluator} = Native.create_cost_evaluator(load_penalties: [20.0], tw_penalty: 20.0, dist_penalty: 20.0)

    for seed <- 1..6, operator <- @node_operators do
      model = model(seed)
      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, start} = Native.create_random_solution(problem_data, seed: seed)

      {:ok, searched} =
        Native.local_search_with_operators(start, problem_data, cost_evaluator,
          node_operators: [operator],
          route_operators: [:swap_routes],
          seed: seed
        )

      assert_precedence(searched, model)
    end
  end

  test "a delivery that fits on its pickup's full route only in place of another client takes that place" do
    # The pickup (1) and its delivery (2) sit together; the far client (3) fills the route. The
    # delivery alone overruns the route by 30s, priced above its prize; dropping the far client
    # alone loses more prize than distance. Only both at once improve.
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(service_duration: 40, required: false, prize: 1_000)
      |> Model.add_client(service_duration: 40, required: false, prize: 1_000)
      |> Model.add_client(service_duration: 40, required: false, prize: 1_000)
      |> Model.add_vehicle_type(num_available: 1, capacity: [10], time_windows: [{0, 210}])
      |> Model.set_euclidean_matrices([{0, 0}, {10, 0}, {11, 0}, {60, 0}])
      |> Model.add_shipment(0, 1, [1])

    {:ok, problem_data} = Model.to_problem_data(model)
    {:ok, start} = Native.create_solution_from_routes(problem_data, [[1, 3]])
    {:ok, cost_evaluator} = Native.create_cost_evaluator(load_penalties: [20.0], tw_penalty: 100.0, dist_penalty: 20.0)

    {:ok, searched} =
      Native.local_search_with_operators(start, problem_data, cost_evaluator, node_operators: [:exchange10])

    assert Native.solution_routes(searched) == [[1, 2]]
  end

  test "RelocateShipment moves a pair to the route it belongs on" do
    # Route 0 runs out east; the pair 3 -> 4 sits west, next to route 1.
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client([])
      |> Model.add_client([])
      |> Model.add_client([])
      |> Model.add_client([])
      |> Model.add_vehicle_type(num_available: 2, capacity: [10])
      |> Model.set_euclidean_matrices([{0, 0}, {100, 0}, {-100, 0}, {-100, 5}, {-105, 5}])
      |> Model.add_shipment(2, 3, [5])

    {:ok, problem_data} = Model.to_problem_data(model)
    {:ok, start} = Native.create_solution_from_routes(problem_data, [[1, 3, 4], [2]])
    {:ok, cost_evaluator} = Native.create_cost_evaluator(load_penalties: [20.0], tw_penalty: 20.0, dist_penalty: 20.0)

    {:ok, searched} =
      Native.local_search_with_operators(start, problem_data, cost_evaluator, node_operators: [:relocate_shipment])

    assert searched |> Native.solution_routes() |> Enum.map(&Enum.sort/1) |> Enum.sort() == [[1], [2, 3, 4]]
    assert_precedence(searched, model)
  end
end

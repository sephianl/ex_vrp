defmodule ExVrp.ShipmentPropertyTest do
  @moduledoc """
  Random instances mixing shipments with depot deliveries, backhauls, reloads,
  optional halves and two load dimensions. Whatever the search does, every
  routed delivery must follow its pickup on the same trip, and each route's
  excess load must match a recomputation from first principles: a trip leaves
  the depot with its clients' deliveries on board, and a shipment's goods are
  on board from its pickup until its delivery, or until the trip ends.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Solution

  @moduletag :nif_required

  @instances 1..12
  @seeds 1..2
  @dims 2

  defp random_model(instance) do
    :rand.seed(:exsss, {instance, 7, 11})

    num_pairs = Enum.random(3..10)
    num_plain = Enum.random(0..6)
    reloads? = rem(instance, 2) == 0

    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_vehicle_type(
        num_available: Enum.random(1..3),
        capacity: [Enum.random(12..30), Enum.random(12..30)],
        reload_depots: if(reloads?, do: [0], else: []),
        max_reloads: 3
      )

    model = Enum.reduce(1..num_plain//1, model, fn _idx, acc -> Model.add_client(acc, plain_client()) end)

    {model, _next} =
      Enum.reduce(1..num_pairs, {model, num_plain}, fn _idx, {acc, next} ->
        {pickup_required, delivery_required} = Enum.random([{true, true}, {true, false}, {false, false}])

        acc =
          acc
          |> Model.add_client(shipment_half(pickup_required))
          |> Model.add_client(shipment_half(delivery_required))
          |> Model.add_shipment(next, next + 1, random_load())

        {acc, next + 2}
      end)

    points = for _idx <- 0..(num_plain + 2 * num_pairs), do: {Enum.random(0..100), Enum.random(0..100)}
    Model.set_euclidean_matrices(model, points)
  end

  defp plain_client do
    [delivery: random_load(), pickup: Enum.map(random_load(), &div(&1, 2)), service_duration: 5]
  end

  defp shipment_half(true), do: [service_duration: 5, delivery: [0, 0], pickup: [0, 0]]

  defp shipment_half(false),
    do: [service_duration: 5, delivery: [0, 0], pickup: [0, 0], required: false, prize: Enum.random(50..400)]

  defp random_load, do: for(_dim <- 1..@dims, do: Enum.random(0..12))

  test "every solution keeps precedence and prices load exactly" do
    for instance <- @instances, seed <- @seeds do
      model = random_model(instance)
      {:ok, result} = ExVrp.solve(model, seed: seed, max_iterations: 200, num_starts: 1)

      check(result.best, model, {instance, seed})
    end
  end

  # The best solutions above carry no excess load, so this also prices the
  # overloaded ones: random starts, and searches that barely mind excess.
  test "overloaded solutions keep precedence and price load exactly" do
    {:ok, cheap_load} = Native.create_cost_evaluator(load_penalties: [1.0, 1.0], tw_penalty: 1.0, dist_penalty: 1.0)

    for instance <- @instances, seed <- @seeds do
      model = random_model(instance)
      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, start} = Native.create_random_solution(problem_data, seed: seed)
      {:ok, searched} = Native.local_search(start, problem_data, cheap_load, seed: seed)

      check(%Solution{solution_ref: start}, model, {:random, instance, seed})
      check(%Solution{solution_ref: searched}, model, {:searched, instance, seed})
    end
  end

  defp check(%Solution{solution_ref: ref}, model, label) do
    clients = List.to_tuple(model.clients)
    signed = signed_shipment_loads(model)
    capacity = hd(model.vehicle_types).capacity

    ref
    |> Native.solution_trips()
    |> Enum.with_index()
    |> Enum.each(fn {trips, route_idx} ->
      client_trips = Enum.map(trips, &Enum.reject(&1.clients, fn client -> elem(clients, client - 1).is_break end))

      Enum.each(client_trips, &assert_trip_precedence(&1, model, label))

      expected =
        Enum.reduce(client_trips, List.duplicate(0, @dims), &add_trip_excess(&1, &2, clients, signed, capacity))

      assert Native.solution_route_excess_load(ref, route_idx) == expected, inspect(label)
    end)
  end

  defp assert_trip_precedence(trip, model, label) do
    positions = trip |> Enum.with_index() |> Map.new()

    for %{pickup: pickup, delivery: delivery} <- model.shipments, Map.has_key?(positions, delivery) do
      assert Map.has_key?(positions, pickup) and positions[pickup] < positions[delivery], inspect(label)
    end
  end

  defp signed_shipment_loads(model) do
    Enum.reduce(model.shipments, %{}, fn %{pickup: pickup, delivery: delivery, amount: amount}, acc ->
      acc |> Map.put(pickup, amount) |> Map.put(delivery, Enum.map(amount, &(-&1)))
    end)
  end

  defp add_trip_excess(trip, excess, clients, signed, capacity) do
    for {{dim_excess, cap}, dim} <- Enum.with_index(Enum.zip(excess, capacity)) do
      dim_excess + max(trip_peak(trip, dim, clients, signed) - cap, 0)
    end
  end

  defp trip_peak(trip, dim, clients, signed) do
    start = Enum.sum_by(trip, &Enum.at(elem(clients, &1 - 1).delivery, dim))

    trip
    |> Enum.scan(start, fn client, load ->
      data = elem(clients, client - 1)
      load - Enum.at(data.delivery, dim) + Enum.at(data.pickup, dim) + Enum.at(Map.get(signed, client, [0, 0]), dim)
    end)
    |> Enum.max(fn -> start end)
    |> max(start)
  end
end

defmodule ExVrp.ShipmentTest do
  @moduledoc """
  Shipments: a pickup client and a delivery client tied together, the delivery
  only after its pickup on the same route and trip.

  The route figures port PyVRP v0.14.0's `tests/test_Route.py` shipment cases
  on its `SmallShipments` instance. Location `i` here is VRPLIB node `i + 1`,
  so U0 = 1, L0 = 2, L1 = 3, U1 = 4, L2 = 5, U2 = 6, U3 = 7, L3 = 8. One
  deliberate difference: upstream rejects a pickup without its delivery, we
  carry its goods back to the depot.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Solution

  @moduletag :nif_required

  @matrix [
    [0, 3785, 2109, 8993, 7823, 6293, 3667, 7925, 9122],
    [3785, 0, 3677, 6332, 5780, 5261, 6700, 4455, 6307],
    [2109, 3677, 0, 9811, 6000, 4280, 3088, 8132, 9847],
    [8993, 6332, 9811, 0, 10_916, 11_200, 12_560, 2941, 447],
    [7823, 5780, 6000, 10_916, 0, 2109, 8249, 8105, 10_701],
    [6293, 5261, 4280, 11_200, 2109, 0, 6198, 8640, 11_064],
    [3667, 6700, 3088, 12_560, 8249, 6198, 0, 11_139, 12_650],
    [7925, 4455, 8132, 2941, 8105, 8640, 11_139, 0, 2647],
    [9122, 6307, 9847, 447, 10_701, 11_064, 12_650, 2647, 0]
  ]

  @windows [
    {7500, 80_900},
    {12_800, 17_900},
    {14_700, 21_900},
    {61_600, 66_100},
    {47_800, 53_100},
    {55_300, 60_200},
    {61_600, 68_000},
    {35_100, 38_600}
  ]

  # {pickup, delivery, amount}: L0 -> U0, L1 -> U1, L2 -> U2, L3 -> U3.
  @pairs [{2, 1, 20}, {3, 4, 30}, {5, 6, 20}, {8, 7, 20}]

  @best_known 65_128

  defp small_shipments(client_opts \\ []) do
    model =
      Model.new()
      |> Model.add_depot(tw_late: 135_100)
      |> Model.add_vehicle_type(num_available: 2, capacity: [50], time_windows: [{0, 135_100}])

    @windows
    |> Enum.reduce(model, fn {early, late}, acc ->
      Model.add_client(acc, [tw_early: early, tw_late: late, service_duration: 900] ++ client_opts)
    end)
    |> add_pairs(@pairs)
    |> Model.set_distance_matrices([@matrix])
    |> Model.set_duration_matrices([@matrix])
  end

  defp add_pairs(model, pairs) do
    Enum.reduce(pairs, model, fn {pickup, delivery, amount}, acc ->
      Model.add_shipment(acc, pickup - 1, delivery - 1, [amount])
    end)
  end

  defp problem_data(model) do
    {:ok, problem_data} = Model.to_problem_data(model)
    problem_data
  end

  defp from_routes(model, routes) do
    Native.create_solution_from_routes(problem_data(model), routes)
  end

  defp solve(model, seed, iterations \\ 500) do
    {:ok, result} = ExVrp.solve(model, seed: seed, max_iterations: iterations, num_starts: 1)
    result.best
  end

  # Every routed delivery follows its pickup within one trip.
  defp assert_precedence(%Solution{solution_ref: ref}, model) do
    trips = ref |> Native.solution_trips() |> Enum.flat_map(& &1) |> Enum.map(& &1.clients)

    for %{pickup: pickup, delivery: delivery} <- model.shipments,
        trip <- trips,
        delivery in trip do
      assert pickup in trip, "delivery #{delivery} on a trip without its pickup #{pickup}"
      assert Enum.find_index(trip, &(&1 == pickup)) < Enum.find_index(trip, &(&1 == delivery))
    end
  end

  describe "reading VRPLIB" do
    test "reads PICKUP_AND_DELIVERY_SECTION into shipment pairs" do
      model = ExVrp.Read.read("priv/benchmark_data/SmallShipments.txt")

      assert Enum.map(model.shipments, &{&1.pickup, &1.delivery, &1.amount}) ==
               Enum.map(@pairs, fn {pickup, delivery, amount} -> {pickup, delivery, [amount]} end)

      assert Enum.map(model.clients, &{&1.tw_early, &1.tw_late, &1.service_duration}) ==
               Enum.map(@windows, fn {early, late} -> {early, late, 900} end)

      assert Enum.all?(model.clients, &(&1.delivery == [0] and &1.pickup == [0]))
    end

    test "the read instance solves to PyVRP's best known solution" do
      model = ExVrp.Read.read("priv/benchmark_data/SmallShipments.txt")
      best = solve(model, 1)

      assert Solution.distance(best) == @best_known
      assert_precedence(best, model)
    end
  end

  describe "validation" do
    test "a model with shipments validates" do
      assert :ok == Model.validate(small_shipments())
    end

    test "add_shipment stores location indices, and add_depot shifts them" do
      model = small_shipments()
      assert %ExVrp.Shipment{pickup: 2, delivery: 1, amount: [20]} = hd(model.shipments)

      shifted = Model.add_depot(model, [])
      assert %ExVrp.Shipment{pickup: 3, delivery: 2} = hd(shifted.shipments)
    end

    test "add_shipment resolves client structs" do
      model = Model.new() |> Model.add_depot([]) |> Model.add_client(name: "a") |> Model.add_client(name: "b")
      [a, b] = model.clients

      assert %ExVrp.Shipment{pickup: 2, delivery: 1} =
               model |> Model.add_shipment(b, a, [0]) |> Map.get(:shipments) |> hd()
    end

    test "rejects a shipment that picks up and delivers at the same client" do
      assert {:error, errors} = small_shipments() |> Model.add_shipment(0, 0, [1]) |> Model.validate()
      assert Enum.any?(errors, &(&1 =~ "same client"))
    end

    test "rejects a client in two shipments" do
      assert {:error, errors} = small_shipments() |> Model.add_shipment(1, 3, [1]) |> Model.validate()
      assert Enum.any?(errors, &(&1 =~ "shares clients"))
    end

    test "rejects an amount with the wrong number of dimensions, or a negative one" do
      model = Model.new() |> Model.add_depot([]) |> Model.add_client([]) |> Model.add_client([])

      model =
        model
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        |> Model.set_euclidean_matrices([{0, 0}, {1, 0}, {2, 0}])

      assert {:error, [error]} = model |> Model.add_shipment(0, 1, [1, 2]) |> Model.validate()
      assert error =~ "dimensions"

      assert {:error, [error]} = model |> Model.add_shipment(0, 1, [-1]) |> Model.validate()
      assert error =~ "negative"
    end

    test "rejects a required delivery whose pickup is optional" do
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(required: false, prize: 10)
        |> Model.add_client([])
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        |> Model.set_euclidean_matrices([{0, 0}, {1, 0}, {2, 0}])
        |> Model.add_shipment(0, 1, [1])

      assert {:error, [error]} = Model.validate(model)
      assert error =~ "required delivery"
    end

    test "rejects an unknown client and a client in a mutually exclusive group" do
      model = Model.add_depot(Model.new(), [])
      {model, group} = Model.add_client_group(model, required: false)

      model =
        model
        |> Model.add_client(required: false, group: group)
        |> Model.add_client(required: false)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        |> Model.set_euclidean_matrices([{0, 0}, {1, 0}, {2, 0}])

      assert {:error, [error]} = model |> Model.add_shipment(0, 7, [1]) |> Model.validate()
      assert error =~ "invalid client index"

      assert {:error, [error]} = model |> Model.add_shipment(0, 1, [1]) |> Model.validate()
      assert error =~ "mutually exclusive"
    end
  end

  describe "routes" do
    test "nested shipments carry their goods from pickup to delivery" do
      model = small_shipments()
      {:ok, ref} = from_routes(model, [[2, 3, 5, 6, 4, 1]])

      assert Native.solution_distance(ref) == 47_132
      assert Native.solution_route_time_warp(ref, 0) == 1611
      assert Native.solution_route_duration(ref, 0) == 47_132 + 6 * 900 + 13_800 + 402

      # L0 loads 20, L1 30, L2 20: 70 on board against a capacity of 50.
      assert Native.solution_route_excess_load(ref, 0) == [20]
    end

    test "a pickup alone carries its goods back to the depot" do
      model = small_shipments()
      {:ok, ref} = from_routes(model, [[2]])

      assert Native.solution_route_pickup(ref, 0) == [20]
      assert Native.solution_route_excess_load(ref, 0) == [0]
      assert Native.solution_num_pickups_without_delivery(ref) == 1
    end

    test "a complete shipment nets out of the route's pickup and delivery" do
      {:ok, ref} = from_routes(small_shipments(), [[2, 1]])

      assert Native.solution_route_pickup(ref, 0) == [0]
      assert Native.solution_route_delivery(ref, 0) == [0]
      assert Native.solution_num_pickups_without_delivery(ref) == 0
    end

    test "rejects a delivery without its pickup, before it, or on another route" do
      model = small_shipments()

      for routes <- [[[1]], [[1, 2]], [[2], [1]]] do
        assert_raise ArgumentError, ~r/not preceded by its pickup/, fn -> from_routes(model, routes) end
      end
    end

    test "rejects a shipment that crosses a reload depot" do
      model = Map.update!(small_shipments(), :vehicle_types, fn [vt] -> [%{vt | reload_depots: [0]}] end)
      trips = {:trips, [%{reload_depot: nil, clients: [2]}, %{reload_depot: 0, clients: [1]}]}

      assert_raise ArgumentError, ~r/same trip/, fn ->
        Native.create_solution_from_routes_with_types(problem_data(model), [{0, trips}])
      end
    end

    test "mixed with clients and reloading, each trip carries only its own load" do
      # Upstream's test_mixed_clients_and_shipments_with_reloading. Its two
      # clients sit at the depot's and U0's locations; here they are clients
      # 9 and 10 with copies of those matrix rows.
      locations = Enum.to_list(0..8) ++ [0, 1]
      matrix = for from <- locations, do: for(to <- locations, do: @matrix |> Enum.at(from) |> Enum.at(to))

      model =
        @windows
        |> Enum.reduce(Model.add_depot(Model.new(), tw_late: 135_100), fn {early, late}, acc ->
          Model.add_client(acc, tw_early: early, tw_late: late, service_duration: 900)
        end)
        |> Model.add_client(delivery: [60])
        |> Model.add_client(delivery: [0])
        |> Model.add_vehicle_type(num_available: 2, capacity: [50], time_windows: [{0, 135_100}], reload_depots: [0])
        |> add_pairs(@pairs)
        |> Model.set_distance_matrices([matrix])
        |> Model.set_duration_matrices([matrix])

      # L0 C0 L1 L2 U0 U1 U2 | C1
      trips = {:trips, [%{reload_depot: nil, clients: [2, 9, 3, 5, 1, 4, 6]}, %{reload_depot: 0, clients: [10]}]}
      {:ok, ref} = Native.create_solution_from_routes_with_types(problem_data(model), [{0, trips}])

      assert Native.solution_distance(ref) == 54_938
      assert Native.solution_route_time_warp(ref, 0) == 2902 + 10_549

      # C0's 60 is loaded at the depot and dominates the trip's peak.
      assert Native.solution_route_excess_load(ref, 0) == [30]
    end

    test "a break between pickup and delivery keeps the shipment" do
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client([])
        |> Model.add_client([])
        |> Model.add_client(required: false, is_break: true)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10], max_drive_between_breaks: 15, break_duration: 5)
        |> Model.set_euclidean_matrices([{0, 0}, {10, 0}, {20, 0}, {0, 0}])
        |> Model.add_shipment(0, 1, [5])

      {:ok, ref} = from_routes(model, [[1, 3, 2]])

      assert Native.solution_route_excess_load(ref, 0) == [0]
      assert Native.solution_num_pickups_without_delivery(ref) == 0
    end

    test "random solutions keep every delivery after its pickup" do
      model = small_shipments()
      data = problem_data(model)

      for seed <- 1..25 do
        {:ok, ref} = Native.create_random_solution(data, seed: seed)
        assert_precedence(%Solution{solution_ref: ref}, model)
      end
    end
  end

  describe "solve" do
    test "reaches PyVRP's best known solution of SmallShipments" do
      model = small_shipments()

      for seed <- 1..3 do
        best = solve(model, seed)

        assert Solution.feasible?(best)
        assert Solution.distance(best) == @best_known
        assert_precedence(best, model)
      end
    end

    test "carries a pickup home when its delivery cannot be made" do
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(required: false, prize: 1_000)
        |> Model.add_client(required: false, prize: 1_000, tw_late: 5)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        |> Model.set_euclidean_matrices([{0, 0}, {10, 0}, {0, 20}])
        |> Model.add_shipment(0, 1, [5])

      best = solve(model, 1, 200)

      assert Solution.feasible?(best)
      assert best.routes == [[1]]
      assert Solution.num_pickups_without_delivery(best) == 1
      assert Solution.unassigned(best) == [2]
    end

    test "skips a whole optional shipment that is not worth its travel" do
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(required: false, prize: 1)
        |> Model.add_client(required: false, prize: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        |> Model.set_euclidean_matrices([{0, 0}, {1_000, 0}, {1_000, 10}])
        |> Model.add_shipment(0, 1, [5])

      best = solve(model, 1, 200)

      assert best.routes == []
      assert Enum.sort(Solution.unassigned(best)) == [1, 2]
    end

    test "orders depot deliveries before a shipment that fills the vehicle" do
      # Client 1 takes all 10 of capacity from the depot; the shipment from 2
      # to 3 fills it again, so only 1, 2, 3 in that order is feasible.
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(delivery: [10])
        |> Model.add_client([])
        |> Model.add_client([])
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        |> Model.set_euclidean_matrices([{0, 0}, {30, 0}, {10, 0}, {20, 0}])
        |> Model.add_shipment(1, 2, [10])

      best = solve(model, 1, 200)

      assert Solution.feasible?(best)
      assert best.routes == [[1, 2, 3]]
    end

    test "never splits a shipment over trips when capacity forces reloads" do
      model =
        Map.update!(small_shipments(), :vehicle_types, fn [vt] ->
          [%{vt | num_available: 1, capacity: [30], reload_depots: [0]}]
        end)

      for seed <- 1..3 do
        best = solve(model, seed)
        assert_precedence(best, model)
      end
    end

    test "keeps shipments together under same-vehicle groups and forbidden locations" do
      # The second vehicle's profile may not visit L1 (location 3).
      model =
        small_shipments()
        |> Model.add_vehicle_type(num_available: 1, capacity: [50], time_windows: [{0, 135_100}], profile: 1)
        |> Model.set_distance_matrices([@matrix, @matrix])
        |> Model.set_duration_matrices([@matrix, @matrix])
        |> Model.add_same_vehicle_group([1, 6])
        |> Model.set_forbidden([[], [3]])

      for seed <- 1..3 do
        best = solve(model, seed)

        assert_precedence(best, model)
        assert Solution.num_forbidden_visits(best) == 0
      end
    end

    test "same-vehicle groups placed up front leave deliveries after their pickups" do
      # The first group places L0 (2); the second holds its delivery U0 (1).
      model =
        small_shipments()
        |> Map.update!(:vehicle_types, fn [vt] -> [%{vt | reload_depots: [0]}] end)
        |> Model.add_same_vehicle_group([1, 4])
        |> Model.add_same_vehicle_group([0, 7])

      for seed <- 1..3 do
        assert_precedence(solve(model, seed, 100), model)
      end
    end

    test "a warm start with a delivery before its pickup falls back to a cold start" do
      model = small_shipments()

      {{:ok, result}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          ExVrp.solve(model, seed: 1, max_iterations: 300, num_starts: 1, initial_routes: [[1, 2]])
        end)

      assert log =~ "not preceded by its pickup"
      assert_precedence(result.best, model)
    end

    test "trims an overloaded warm start without splitting its shipment" do
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(required: false, prize: 10)
        |> Model.add_client(required: false, prize: 10)
        |> Model.add_vehicle_type(num_available: 1, capacity: [5])
        |> Model.set_euclidean_matrices([{0, 0}, {10, 0}, {20, 0}])
        |> Model.add_shipment(0, 1, [10])

      {{:ok, result}, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          ExVrp.solve(model, seed: 1, max_iterations: 100, num_starts: 1, initial_routes: [[1, 2]])
        end)

      assert Solution.feasible?(result.best)
      assert_precedence(result.best, model)
    end
  end
end

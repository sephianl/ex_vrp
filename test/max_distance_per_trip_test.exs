defmodule ExVrp.MaxDistancePerTripTest do
  @moduledoc """
  Tests for `:max_distance_per_trip`, the distance cap that resets at every
  reload.

  `:max_distance` bounds the whole route, summed over its trips, so reloading
  buys no extra range. That is the wrong model for a vehicle that refuels or
  charges while it is at the depot, whose real limit is one tank per trip. The
  two caps are independent, and most of what follows pins down which one bites.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  # Depot at 0, clients at 10 and 20 on a line. Each client's delivery fills
  # the vehicle, so a client costs one whole trip and the route must reload
  # between them:
  #
  #     trip to the near client: 0 -> 10 -> 0 = 20
  #     trip to the far client:  0 -> 20 -> 0 = 40
  #
  # The route is 60 long and made of two trips, 20 and 40. Every cap below sits
  # deliberately between those numbers, so which constraint bites is forced
  # rather than incidental.
  defp two_trip_model(vehicle_opts) do
    Model.new()
    |> Model.add_depot([])
    |> Model.add_client(delivery: [80])
    |> Model.add_client(delivery: [80])
    |> Model.add_vehicle_type(
      Keyword.merge(
        [num_available: 1, capacity: [100], reload_depots: [0], max_reloads: 5],
        vehicle_opts
      )
    )
    |> Model.set_euclidean_matrices([{0, 0}, {10, 0}, {20, 0}])
  end

  defp solve(vehicle_opts) do
    {:ok, result} =
      Solver.solve(two_trip_model(vehicle_opts), stop: StoppingCriteria.max_iterations(200))

    result.best
  end

  # The case the whole feature exists for, at the numbers it was argued in.
  # Depot at 0, one client at 70 and one at 60, each filling the vehicle, so
  # each costs its own trip:
  #
  #     trip to the far client:  0 -> 70 -> 0 = 140
  #     trip to the near client: 0 -> 60 -> 0 = 120
  #
  # 260 across the day, and a 250 vehicle. Whether that is allowed is exactly
  # the difference between the two caps.
  defp two_shift_model(vehicle_opts) do
    Model.new()
    |> Model.add_depot([])
    |> Model.add_client(delivery: [80])
    |> Model.add_client(delivery: [80])
    |> Model.add_vehicle_type(
      Keyword.merge(
        [num_available: 1, capacity: [100], reload_depots: [0], max_reloads: 5],
        vehicle_opts
      )
    )
    |> Model.set_euclidean_matrices([{0, 0}, {70, 0}, {60, 0}])
  end

  defp solve_two_shifts(vehicle_opts) do
    {:ok, result} =
      Solver.solve(two_shift_model(vehicle_opts), stop: StoppingCriteria.max_iterations(300))

    result.best
  end

  describe "140 + 120 on a 250 vehicle" do
    test "the day total is 260 over two trips" do
      solution = solve_two_shifts([])

      assert Solution.complete?(solution)
      assert Solution.distance(solution) == 260
    end

    test "as a whole-route cap, 250 is breached by 10" do
      solution = solve_two_shifts(max_distance: 250)

      assert Solution.excess_distance(solution) == 10
      refute Solution.feasible?(solution)
    end

    test "as a per-trip cap, 250 is not breached at all" do
      solution = solve_two_shifts(max_distance_per_trip: 250)

      assert Solution.excess_distance(solution) == 0
      assert Solution.feasible?(solution)
      assert Solution.distance(solution) == 260
    end

    test "a per-trip cap still binds the longer trip on its own" do
      solution = solve_two_shifts(max_distance_per_trip: 130)

      assert Solution.excess_distance(solution) == 10
    end

    test "both caps together bind independently" do
      solution = solve_two_shifts(max_distance: 250, max_distance_per_trip: 130)

      assert Solution.excess_distance(solution) == 20
    end
  end

  # The counterpart the distance caps do not have. Duration is bounded for the
  # whole route only -- there is no per-trip duration cap -- so a second shift
  # spends the same budget the first one drew on. This is the asymmetry that
  # makes "which cap covers what" worth stating explicitly.
  describe "the duration counterpart" do
    test "max_duration bounds the day, so two trips spend one budget" do
      fits_one_trip = solve_two_shifts(max_duration: 200)
      fits_both = solve_two_shifts(max_duration: 400)

      assert Solution.time_warp(fits_one_trip) > 0
      assert Solution.time_warp(fits_both) == 0
    end

    test "a distance cap that resets per trip does not make duration reset too" do
      solution = solve_two_shifts(max_distance_per_trip: 250, max_duration: 200)

      assert Solution.excess_distance(solution) == 0
      assert Solution.time_warp(solution) > 0
    end
  end

  describe "scope" do
    test "a cap of 50 on the whole route is breached by a 60-long route" do
      solution = solve(max_distance: 50)

      assert Solution.excess_distance(solution) > 0
    end

    test "the same 50 per trip is not breached, because no trip exceeds 40" do
      solution = solve(max_distance_per_trip: 50)

      assert Solution.excess_distance(solution) == 0
      assert Solution.complete?(solution)
    end

    test "a trip beyond the per-trip cap is excess" do
      solution = solve(max_distance_per_trip: 30)

      assert Solution.excess_distance(solution) > 0
    end

    test "the two caps are independent and compose" do
      assert Solution.excess_distance(solve(max_distance: 100, max_distance_per_trip: 50)) == 0
      assert Solution.excess_distance(solve(max_distance: 50, max_distance_per_trip: 50)) > 0
      assert Solution.excess_distance(solve(max_distance: 100, max_distance_per_trip: 30)) > 0
    end

    test "an unset per-trip cap constrains nothing" do
      assert Solution.excess_distance(solve([])) == 0
    end

    # Delta evaluation and update() compute the per-trip excess by different
    # routes, and local search oscillates forever if the two ever disagree
    # about the same arrangement. A run that does not terminate is the symptom,
    # so this asserts termination on an instance with many reloads to move
    # through rather than any particular objective value.
    test "a per-trip cap over many reloads converges" do
      model =
        1..12
        |> Enum.reduce(Model.add_depot(Model.new(), []), fn _idx, acc ->
          Model.add_client(acc, delivery: [60])
        end)
        |> Model.add_vehicle_type(
          num_available: 2,
          capacity: [100],
          reload_depots: [0],
          max_reloads: 20,
          max_distance_per_trip: 45
        )
        |> Model.set_euclidean_matrices([
          {0, 0},
          {10, 0},
          {20, 0},
          {0, 10},
          {0, 20},
          {-10, 0},
          {-20, 0},
          {0, -10},
          {0, -20},
          {15, 15},
          {-15, 15},
          {15, -15},
          {-15, -15}
        ])

      {:ok, result} = Solver.solve(model, stop: StoppingCriteria.max_iterations(500))

      assert Solution.complete?(result.best)
    end
  end

  defp search_route(vehicle_opts) do
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_vehicle_type(Keyword.merge([num_available: 1, capacity: [10]], vehicle_opts))
      |> Model.set_distance_matrices([[[0]]])
      |> Model.set_duration_matrices([[[0]]])

    {:ok, problem_data} = Model.to_problem_data(model)
    Native.create_search_route_nif(problem_data, 0, 0)
  end

  describe "local search visibility" do
    # `hasDistanceCost` gates whether `CostEvaluator::deltaCost` prices
    # distance at all. A per-trip cap missing from that gate is a cap local
    # search never sees, so it would create and worsen violations for free --
    # the bug fixed for overtime in v0.8.0. The configuration below is the one
    # most likely to be shipped, and the one that would trip it: a per-trip cap
    # with no whole-route cap and no distance cost.
    test "a per-trip cap alone still makes local search price distance" do
      route = search_route(unit_distance_cost: 0, max_distance_per_trip: 100)

      assert Native.search_route_has_distance_cost_nif(route) == true
    end

    test "no cap and no distance cost still prices nothing" do
      route = search_route(unit_distance_cost: 0)

      assert Native.search_route_has_distance_cost_nif(route) == false
    end
  end

  # Depot at 0, clients at 30, 60 and 90 on a line, and a 100 per-trip cap, so
  # every trip below sits either side of it rather than on it.
  defp line_problem do
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(delivery: [0])
      |> Model.add_client(delivery: [0])
      |> Model.add_client(delivery: [0])
      |> Model.add_vehicle_type(
        num_available: 1,
        capacity: [100],
        reload_depots: [0],
        max_reloads: 5,
        unit_distance_cost: 0,
        max_distance_per_trip: 100
      )
      |> Model.set_euclidean_matrices([{0, 0}, {30, 0}, {60, 0}, {90, 0}])

    {:ok, problem_data} = Model.to_problem_data(model)

    {:ok, cost_evaluator} =
      Native.create_cost_evaluator(load_penalties: [0.0], tw_penalty: 0.0, dist_penalty: 1.0)

    {problem_data, cost_evaluator}
  end

  defp excess_of(problem_data, visits) do
    problem_data
    |> Native.make_search_route_nif(visits, 0, 0)
    |> Native.search_route_excess_distance_nif()
  end

  describe "delta evaluation agrees with recomputation" do
    # Local search never rebuilds a route to price a move -- it folds the
    # untouched segments around the change. That fold has to draw the trip
    # boundaries exactly where `update()` draws them, and the one arc where the
    # two can disagree is the arc *into* a reload depot: it is the closing leg
    # of the trip that ends there, not the opening leg of the next one. Put it
    # in the wrong trip and the delta is off by the clipped difference, so
    # local search creates per-trip violations it believes are free, and the
    # two paths fight over the same arrangement forever.
    #
    # Distance costs nothing here and only excess distance is penalised, so a
    # delta is exactly the change in excess, which the rebuilt route gives
    # independently.

    test "inserting before a reload depot leaves the arc into it in the closing trip" do
      {problem_data, cost_evaluator} = line_problem()

      route = Native.make_search_route_nif(problem_data, [1, 0, 2], 0, 0)
      after_client_1 = Native.search_route_get_node_nif(route, 1)
      client_3 = Native.create_search_node_nif(problem_data, 3)

      delta = Native.insert_cost_nif(client_3, after_client_1, problem_data, cost_evaluator)

      assert delta ==
               excess_of(problem_data, [1, 3, 0, 2]) - excess_of(problem_data, [1, 0, 2])
    end

    test "opening a new trip leaves the arc into the new depot in the closing trip" do
      {problem_data, cost_evaluator} = line_problem()

      route = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      client_3 = Native.create_search_node_nif(problem_data, 3)

      delta =
        Native.insert_trip_cost_nif(client_3, route, 0, 2, problem_data, cost_evaluator)

      assert delta == excess_of(problem_data, [1, 0, 3, 2]) - excess_of(problem_data, [1, 2])
    end
  end

  describe "vehicle type" do
    test "defaults to unconstrained" do
      vt = ExVrp.VehicleType.new(num_available: 1, capacity: [10])

      assert vt.max_distance_per_trip == :infinity
    end

    test "carries the value it was given" do
      vt = ExVrp.VehicleType.new(num_available: 1, capacity: [10], max_distance_per_trip: 250)

      assert vt.max_distance_per_trip == 250
    end
  end
end

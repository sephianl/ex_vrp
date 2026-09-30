defmodule ExVrp.BreakNodesTest do
  @moduledoc """
  Break clients have no location: every edge skips them, so they add only
  their duration. Client 3 is the break; its matrix row points far away so
  that any lookup that reads it shows up as extra distance.

  In the proposal tests client 4 sits off the line, so moves change distance,
  and client 2 opens late, so where the break lands decides whether it absorbs
  waiting and the duration fold matters as well as the distance fold.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Route
  alias ExVrp.Solution

  @moduletag :nif_required

  @break 3
  @break_duration 45
  @break_rule [max_drive_between_breaks: 270, break_duration: @break_duration]
  @points [{0, 0}, {10, 0}, {30, 0}, {1000, 0}, {0, 50}]

  defp model(opts) do
    vehicle =
      Keyword.merge(
        [num_available: 2, capacity: [0], unit_distance_cost: 1, unit_duration_cost: 1] ++ @break_rule,
        Keyword.get(opts, :vehicle, [])
      )

    service = [service_duration: Keyword.get(opts, :service, 0)]

    Model.new()
    |> Model.add_depot([])
    |> Model.add_client(tw_window(opts[:client_1_tw]) ++ service)
    |> Model.add_client(tw_window(opts[:client_2_tw]) ++ service)
    |> Model.add_client(required: false, is_break: true)
    |> Model.add_client(service)
    |> Model.add_vehicle_type(vehicle)
    |> Model.add_vehicle_type(Keyword.merge(vehicle, Keyword.get(opts, :second_vehicle, [])))
    |> Model.set_euclidean_matrices(Keyword.get(opts, :points, @points))
  end

  defp tw_window(nil), do: []
  defp tw_window({early, late}), do: [tw_early: early, tw_late: late]

  defp problem_data(opts \\ []) do
    {:ok, problem_data} = opts |> model() |> Model.to_problem_data()
    problem_data
  end

  defp solution(visits, opts) do
    {:ok, ref} = Native.create_solution_from_routes(problem_data(opts), [visits])
    %Solution{solution_ref: ref, routes: [visits]}
  end

  defp stats(visits, opts \\ []) do
    route = visits |> solution(opts) |> Solution.routes() |> hd()

    %{
      distance: Route.distance(route),
      duration: Route.duration(route),
      travel: Route.travel_duration(route),
      service: Route.service_duration(route),
      wait: Route.wait_duration(route),
      time_warp: Route.time_warp(route),
      clock_excess: Route.clock_excess(route)
    }
  end

  describe "stored routes" do
    test "a break between two clients costs no distance and adds its duration" do
      plain = stats([1, 2])
      with_break = stats([1, @break, 2])

      assert with_break.distance == plain.distance
      assert with_break.travel == plain.travel
      assert with_break.duration == plain.duration + @break_duration
    end

    test "a break is rest: neither service nor waiting" do
      plain = stats([1, 2])
      with_break = stats([1, @break, 2])

      assert with_break.service == plain.service
      assert with_break.wait == plain.wait
    end

    test "the break lasts the vehicle type's break duration" do
      opts = [vehicle: [break_duration: 60]]

      assert stats([1, @break, 2], opts).duration == stats([1, 2], opts).duration + 60
    end

    test "a break fits inside the wait for a late-opening client instead of adding time" do
      opts = [client_1_tw: {0, 15}, client_2_tw: {130, 10_000}]

      assert stats([1, @break, 2], opts).duration == stats([1, 2], opts).duration
    end

    test "breaks at either end of the route cost no distance" do
      assert stats([@break, 1, 2]).distance == stats([1, 2]).distance
      assert stats([1, 2, @break]).distance == stats([1, 2]).distance
    end

    test "the search route agrees with the solution route" do
      data = problem_data()
      search_route = Native.make_search_route_nif(data, [1, @break, 2], 0, 0)

      assert Native.search_route_distance_nif(search_route) == stats([1, 2]).distance
      assert Native.search_route_duration_nif(search_route) == stats([1, @break, 2]).duration
    end
  end

  describe "proposals" do
    @opts [client_2_tw: {100, 10_000}]
    @routes {[1, @break, 2], [4]}

    defp route_cost(route), do: route_cost(route, Native.search_route_empty_nif(route))

    defp route_cost(_route, true = _empty), do: 0

    defp route_cost(route, false = _empty) do
      Native.search_route_fixed_vehicle_cost_nif(route) + Native.search_route_distance_cost_nif(route) +
        Native.search_route_duration_cost_nif(route) + Native.search_route_time_warp_nif(route) +
        Native.search_route_excess_distance_nif(route)
    end

    defp operator(:exchange10),
      do: {&Native.create_exchange10_nif/1, &Native.exchange10_evaluate_nif/4, &Native.exchange10_apply_nif/3}

    defp operator(:exchange20),
      do: {&Native.create_exchange20_nif/1, &Native.exchange20_evaluate_nif/4, &Native.exchange20_apply_nif/3}

    defp operator(:exchange21),
      do: {&Native.create_exchange21_nif/1, &Native.exchange21_evaluate_nif/4, &Native.exchange21_apply_nif/3}

    defp operator(:swap_tails),
      do: {&Native.create_swap_tails_nif/1, &Native.swap_tails_evaluate_nif/4, &Native.swap_tails_apply_nif/3}

    defp assert_delta_matches_applied(name, {visits1, visits2}, u_idx, v_idx, opts) do
      {create, evaluate, apply} = operator(name)
      data = problem_data(opts)
      {:ok, evaluator} = Native.create_cost_evaluator(load_penalties: [0.0], tw_penalty: 1.0, dist_penalty: 1.0)

      route1 = Native.make_search_route_nif(data, visits1, 0, 0)
      # Vehicle type 1 equals type 0 unless opts[:second_vehicle] says otherwise.
      route2 = Native.make_search_route_nif(data, visits2, 1, 1)
      before = route_cost(route1) + route_cost(route2)

      op = create.(data)
      u = Native.search_route_get_node_nif(route1, u_idx)
      v = Native.search_route_get_node_nif(route2, v_idx)
      delta = evaluate.(op, u, v, evaluator)

      :ok = apply.(op, u, v)
      Native.search_route_update_nif(route1)
      Native.search_route_update_nif(route2)

      assert delta == route_cost(route1) + route_cost(route2) - before
      delta
    end

    test "Exchange10 leaving a break at the head of the rest of the route" do
      assert assert_delta_matches_applied(:exchange10, @routes, 1, 1, @opts) != 0
    end

    test "Exchange10 moving a lone break into another route" do
      assert_delta_matches_applied(:exchange10, @routes, 2, 1, @opts)
    end

    test "Exchange10 moving a lone break into another route, under a per-trip distance cap" do
      opts = [{:vehicle, [max_distance_per_trip: 40]} | @opts]

      assert_delta_matches_applied(:exchange10, @routes, 2, 1, opts)
    end

    test "Exchange20 moving a segment that starts with a break" do
      assert_delta_matches_applied(:exchange20, @routes, 2, 1, @opts)
    end

    test "Exchange20 moving a segment that ends with a break" do
      assert_delta_matches_applied(:exchange20, @routes, 1, 0, @opts)
    end

    test "Exchange21 swapping a pair of clients for a lone break" do
      assert assert_delta_matches_applied(:exchange21, {[1, 2], [4, @break]}, 1, 2, @opts) != 0
    end

    test "SwapTails moving a tail that starts with a break" do
      assert_delta_matches_applied(:swap_tails, @routes, 1, 1, @opts)
    end

    test "SwapTails moving a tail after a break" do
      assert_delta_matches_applied(:swap_tails, @routes, 2, 0, @opts)
    end

    test "Exchange10 leaving a break right before a reload depot, under a per-trip distance cap" do
      opts = [vehicle: [reload_depots: [0], max_reloads: 1, max_distance_per_trip: 40]]

      assert assert_delta_matches_applied(:exchange10, {[1, @break, 0, 2], [4]}, 1, 1, opts) != 0
    end
  end

  describe "drive clock" do
    # Clients at 100 and 150 on the line, so route [1, 2] drives 100 + 50 +
    # 150 = 300, past the break rule's 270.
    @long [points: [{0, 0}, {100, 0}, {150, 0}, {1000, 0}, {0, 50}]]

    test "driving past the limit without a break is clock excess, counted as time warp" do
      plain = stats([1, 2], @long)

      assert plain.clock_excess == 30
      assert plain.time_warp == 30
    end

    test "a break on the last leg splits the drive into 150 + 150" do
      plain = stats([1, 2], @long)
      with_break = stats([1, 2, @break], @long)

      assert with_break.clock_excess == 0
      assert with_break.time_warp == 0
      assert with_break.duration == plain.duration + @break_duration
    end

    test "a break on the first leg resets the clock before any driving" do
      assert stats([@break, 1, 2], @long).clock_excess == 30
    end

    test "each extra break on a leg pre-pays the limit of that leg's drive" do
      # Client 1 sits 700 out, so the route drives 700 there and 700 back.
      # Clients 2 and 3 are both breaks.
      {:ok, data} =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client([])
        |> Model.add_client(required: false, is_break: true)
        |> Model.add_client(required: false, is_break: true)
        |> Model.add_vehicle_type([num_available: 1, capacity: [0]] ++ @break_rule)
        |> Model.set_euclidean_matrices([{0, 0}, {700, 0}, {0, 0}, {0, 0}])
        |> Model.to_problem_data()

      excess = fn visits ->
        {:ok, ref} = Native.create_solution_from_routes(data, [visits])
        %Solution{solution_ref: ref, routes: [visits]} |> Solution.routes() |> hd() |> Route.clock_excess()
      end

      # One break on the way out resets the clock before any drive: 1400 left.
      assert excess.([2, 1]) == 1400 - 270
      # A second one pre-pays 270 of the outbound 700: 430 + 700 left.
      assert excess.([2, 3, 1]) == 1130 - 270
      # Breaks on the way back: 700 before them, 700 - 270 after.
      assert excess.([1, 2, 3]) == 700 - 270 + (430 - 270)
    end

    test "clock excess does not move the end time" do
      route = [1, 2] |> solution(@long) |> Solution.routes() |> hd()

      assert Route.end_time(route) == Route.start_time(route) + Route.duration(route)
    end

    test "the search prices the missing break as its duration, not as time warp" do
      data = problem_data(@long)
      search_route = Native.make_search_route_nif(data, [1, 2], 0, 0)
      plain = stats([1, 2], @long)

      assert plain.time_warp == 30
      assert Native.search_route_virtual_breaks_nif(search_route) == 1
      assert Native.search_route_time_warp_nif(search_route) == 0
      assert Native.search_route_duration_nif(search_route) == plain.duration + @break_duration
    end

    test "a real break replaces the virtual one" do
      data = problem_data(@long)
      search_route = Native.make_search_route_nif(data, [1, 2, @break], 0, 0)

      assert Native.search_route_virtual_breaks_nif(search_route) == 0
      assert Native.search_route_duration_nif(search_route) == stats([1, 2, @break], @long).duration
    end

    test "a stretch past twice the limit lacks two breaks" do
      data = problem_data([vehicle: [max_drive_between_breaks: 140]] ++ @long)
      search_route = Native.make_search_route_nif(data, [1, 2], 0, 0)

      assert Native.search_route_virtual_breaks_nif(search_route) == 2
    end

    test "a missing break that runs past the vehicle's latest end is time warp" do
      # [1, 2] drives 300 and ends at 300; with the virtual break at 345.
      data = problem_data([vehicle: [time_windows: [{0, 320}]]] ++ @long)
      search_route = Native.make_search_route_nif(data, [1, 2], 0, 0)

      assert Native.search_route_time_warp_nif(search_route) == 25
    end

    test "a missing break counts against the maximum duration" do
      data = problem_data([vehicle: [max_duration: 330]] ++ @long)
      search_route = Native.make_search_route_nif(data, [1, 2], 0, 0)

      assert Native.search_route_time_warp_nif(search_route) == 15
    end

    test "inserting a break is priced by the delta exactly as applied" do
      # Moving the break off [4] saves its 45; on [1, 2] it costs 45 but
      # replaces the virtual break, which cost 45 too.
      assert assert_delta_matches_applied(:exchange10, {[4, @break], [1, 2]}, 2, 1, @long) == -45
    end

    test "moving the last client off a route with a break empties it, and saves its fixed cost" do
      routes = {[4, @break], [1, 2]}
      free = assert_delta_matches_applied(:exchange10, routes, 1, 1, @long)
      fixed = assert_delta_matches_applied(:exchange10, routes, 1, 1, [{:vehicle, [fixed_cost: 1_000]} | @long])

      assert fixed == free - 1_000
    end

    test "SwapTails that leaves a route only a break empties it, and saves its fixed cost" do
      # Client 4's tail is the lone break, and it swaps with all of [1, 2]:
      # the second route keeps only the break.
      routes = {[4, @break], [1, 2]}
      free = assert_delta_matches_applied(:swap_tails, routes, 1, 0, @long)
      fixed = assert_delta_matches_applied(:swap_tails, routes, 1, 0, [{:vehicle, [fixed_cost: 1_000]} | @long])

      assert fixed == free - 1_000
    end

    test "every proposal case agrees with its applied change under an active clock" do
      cases = [
        {:exchange10, {[1, @break, 2], [4]}, 1, 1},
        {:exchange10, {[1, @break, 2], [4]}, 2, 1},
        {:exchange10, {[4, @break], [1, 2]}, 2, 0},
        {:exchange20, {[1, @break, 2], [4]}, 2, 1},
        {:exchange20, {[1, @break, 2], [4]}, 1, 0},
        {:exchange21, {[1, 2], [4, @break]}, 1, 2},
        {:swap_tails, {[1, @break, 2], [4]}, 1, 1},
        {:swap_tails, {[1, @break, 2], [4]}, 2, 0},
        {:swap_tails, {[1, 2], [4, @break]}, 1, 1},
        {:swap_tails, {[@break, 1, 2], [4]}, 0, 0}
      ]

      for {name, routes, u, v} <- cases do
        assert_delta_matches_applied(name, routes, u, v, @long)
      end
    end

    test "a break moved to another vehicle type takes that type's break duration" do
      # Type 1's breaks last 60, not 45, and its limit is lower, so both the
      # duration and the clock differ once the break crosses over.
      opts = [{:second_vehicle, [max_drive_between_breaks: 200, break_duration: 60]} | @long]

      for {name, routes, u, v} <- [
            {:exchange10, {[1, @break, 2], [4]}, 2, 1},
            {:exchange20, {[1, @break, 2], [4]}, 1, 0},
            {:exchange10, {[4, @break], [1, 2]}, 2, 1},
            {:swap_tails, {[1, @break, 2], [4]}, 1, 1},
            {:swap_tails, {[1, 2], [4, @break]}, 1, 1}
          ] do
        assert_delta_matches_applied(name, routes, u, v, opts)
      end
    end
  end

  describe "working-time clock and carries" do
    # A square with 1.5 h sides: stops 1..4 at its corners, stop 4 back on the
    # depot, so the route [1, 2, 3, 4] drives four 1.5 h legs (6 h) and a 0 s
    # leg home, with 1 h of service at each stop (4 h). Client 5 is the break.
    @hour 3_600
    @square [{0, 0}, {5_400, 0}, {5_400, 5_400}, {0, 5_400}, {0, 0}, {100_000, 0}]
    @work_break 5

    defp square_stats(visits, vehicle) do
      {:ok, data} =
        Model.new()
        |> Model.add_depot([])
        |> then(fn model -> Enum.reduce(1..4, model, fn _i, m -> Model.add_client(m, service_duration: @hour) end) end)
        |> Model.add_client(required: false, is_break: true)
        |> Model.add_vehicle_type([num_available: 1, capacity: [0]] ++ vehicle)
        |> Model.set_euclidean_matrices(@square)
        |> Model.to_problem_data()

      {:ok, ref} = Native.create_solution_from_routes(data, [visits])
      route = %Solution{solution_ref: ref, routes: [visits]} |> Solution.routes() |> hd()
      search_route = Native.make_search_route_nif(data, visits, 0, 0)

      %{
        work: Route.work_clock_excess(route),
        drive: Route.clock_excess(route),
        time_warp: Route.time_warp(route),
        timeline: Route.end_time(route) - Route.start_time(route) - Route.duration(route),
        duration: Route.duration(route),
        search_time_warp: Native.search_route_time_warp_nif(search_route),
        search_timeline: Native.search_route_timeline_time_warp_nif(search_route),
        search_duration: Native.search_route_duration_nif(search_route),
        virtual_breaks: Native.search_route_virtual_breaks_nif(search_route)
      }
    end

    @work_break_duration 1_800
    @work_rule [max_work_between_breaks: 18_000, break_duration: @work_break_duration]

    test "work past the limit without a break overruns; a break after the second stop clears it" do
      # No break: one stretch of 4 x (1.5 h + 1 h) = 10 h, 5 h over.
      plain = square_stats([1, 2, 3, 4], @work_rule)
      assert plain.work == 18_000
      assert plain.drive == 0
      assert plain.time_warp == 18_000
      assert plain.timeline == 0

      # The search prices the missing break as its duration instead.
      assert plain.virtual_breaks == 1
      assert plain.search_time_warp == 0
      assert plain.search_timeline == 0
      assert plain.search_duration == plain.duration + @work_break_duration

      # A break on leg 2 -> 3: stretches of 2 x 2.5 h = 5 h each, both at the limit.
      with_break = square_stats([1, 2, @work_break, 3, 4], @work_rule)
      assert with_break.work == 0
      assert with_break.virtual_breaks == 0
    end

    test "work carried in overruns one stop earlier" do
      # 1 h carried in makes the first stretch 1 h + 5 h = 6 h: the break after
      # the second stop no longer suffices, 1 h over, and one break is missing.
      stats = square_stats([1, 2, @work_break, 3, 4], [work_carry_in: @hour] ++ @work_rule)

      assert stats.work == @hour
      assert stats.virtual_breaks == 1
      assert stats.search_duration == stats.duration + @work_break_duration
    end

    test "work after the end of the route joins its last stretch" do
      # The last stretch is 5 h, exactly the limit; 30 min of unloading after
      # the end makes it 30 min over.
      stats = square_stats([1, 2, @work_break, 3, 4], [work_after_end: 1_800] ++ @work_rule)

      assert stats.work == 1_800
      assert stats.virtual_breaks == 1
    end

    test "driving carried in joins the first stretch of the drive clock" do
      # 3.5 h of driving carried in leaves 30 min to the 4 h limit. Stop 1 at
      # 900 s from the depot is a 30 min round trip: 0 over. Stop 2 at 1 800 s
      # is a 1 h round trip: 3 600 - 1 800 = 1 800 over, one break missing.
      points = [{0, 0}, {900, 0}, {1_800, 0}, {0, 0}, {0, 0}, {100_000, 0}]
      rule = [max_drive_between_breaks: 14_400, break_duration: 1_800, drive_carry_in: 12_600]

      {:ok, data} =
        Model.new()
        |> Model.add_depot([])
        |> then(fn model -> Enum.reduce(1..4, model, fn _i, m -> Model.add_client(m, []) end) end)
        |> Model.add_client(required: false, is_break: true)
        |> Model.add_vehicle_type([num_available: 1, capacity: [0]] ++ rule)
        |> Model.set_euclidean_matrices(points)
        |> Model.to_problem_data()

      excess = fn visits ->
        {:ok, ref} = Native.create_solution_from_routes(data, [visits])
        search_route = Native.make_search_route_nif(data, visits, 0, 0)
        route = %Solution{solution_ref: ref, routes: [visits]} |> Solution.routes() |> hd()
        {Route.clock_excess(route), Native.search_route_virtual_breaks_nif(search_route)}
      end

      assert excess.([1]) == {0, 0}
      assert excess.([2]) == {1_800, 1}
      # A break on the way out resets the clock before any of the 1 h: 0 over.
      assert excess.([@work_break, 2]) == {0, 0}
    end

    test "every proposal case agrees with its applied change under both clocks and carries" do
      # [1, 2] drives 300 and serves 2 x 20: work 30 carried in + 340 + 20
      # after the end = 390, over the 300 work limit, so the work clock is live.
      rule = [max_drive_between_breaks: 270, max_work_between_breaks: 300, break_duration: @break_duration]

      opts =
        [
          service: 20,
          vehicle: rule ++ [work_carry_in: 30, work_after_end: 20, drive_carry_in: 10],
          second_vehicle: [work_carry_in: 0, work_after_end: 50, drive_carry_in: 40]
        ] ++ @long

      cases = [
        {:exchange10, {[1, @break, 2], [4]}, 1, 1},
        {:exchange10, {[1, @break, 2], [4]}, 2, 1},
        {:exchange10, {[4, @break], [1, 2]}, 2, 0},
        {:exchange10, {[4, @break], [1, 2]}, 2, 1},
        {:exchange10, {[4], [1, 2]}, 1, 0},
        {:exchange20, {[1, @break, 2], [4]}, 2, 1},
        {:exchange20, {[1, @break, 2], [4]}, 1, 0},
        {:exchange21, {[1, 2], [4, @break]}, 1, 2},
        {:swap_tails, {[1, @break, 2], [4]}, 1, 1},
        {:swap_tails, {[1, @break, 2], [4]}, 2, 0},
        {:swap_tails, {[1, 2], [4, @break]}, 1, 1},
        {:swap_tails, {[@break, 1, 2], [4]}, 0, 0}
      ]

      for {name, routes, u, v} <- cases do
        assert_delta_matches_applied(name, routes, u, v, opts)
      end
    end
  end

  describe "validation" do
    defp validate_vehicle(vehicle) do
      Model.new()
      |> Model.add_depot([])
      |> Model.add_vehicle_type([num_available: 1, capacity: [0]] ++ vehicle)
      |> Model.set_euclidean_matrices([{0, 0}])
      |> Model.validate()
    end

    test "a limit needs a break duration, and a break duration a limit" do
      for vehicle <- [[max_work_between_breaks: 300], [max_drive_between_breaks: 270], [break_duration: 45]] do
        assert {:error, [message]} = validate_vehicle(vehicle)
        assert message =~ "break_duration must be positive exactly when"
      end

      assert validate_vehicle(max_drive_between_breaks: 270, break_duration: 45) == :ok
    end

    test "a carry that alone overruns its limit is rejected, as no break can fix it" do
      rule = [max_drive_between_breaks: 270, max_work_between_breaks: 300, break_duration: 45]

      for carry <- [[drive_carry_in: 271], [work_carry_in: 301], [work_after_end: 301]] do
        assert {:error, [message]} = validate_vehicle(rule ++ carry)
        assert message =~ "exceeds its limit between breaks"
      end

      assert validate_vehicle(rule ++ [drive_carry_in: 270, work_carry_in: 300]) == :ok
    end

    test "a limit that is not positive is rejected before the pool is sized" do
      for limit <- [[max_drive_between_breaks: 0], [max_work_between_breaks: -5]] do
        assert {:error, [message]} = validate_vehicle([break_duration: 45] ++ limit)
        assert message =~ "must be positive or :infinity"
      end
    end
  end

  test "a break client cannot be required" do
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(required: true, is_break: true)
      |> Model.add_vehicle_type(num_available: 1, capacity: [0])
      |> Model.set_euclidean_matrices([{0, 0}, {0, 0}])

    assert_raise ArgumentError, ~r/break clients must not be required/, fn ->
      Model.to_problem_data(model)
    end
  end

  test "limits between breaks without a pool of break clients are rejected" do
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(delivery: [1])
      |> Model.add_vehicle_type(num_available: 1, capacity: [1], max_drive_between_breaks: 270, break_duration: 45)
      |> Model.set_euclidean_matrices([{0, 0}, {100, 0}])

    assert_raise ArgumentError, ~r/no break clients/, fn -> Native.create_problem_data(model) end
  end

  test "a break client with a service duration is rejected" do
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(required: false, is_break: true, service_duration: 45)
      |> Model.add_vehicle_type(num_available: 1, capacity: [0])
      |> Model.set_euclidean_matrices([{0, 0}, {0, 0}])

    assert_raise ArgumentError, ~r/break clients take their duration from the vehicle type/, fn ->
      Model.to_problem_data(model)
    end
  end

  test "a break client with a time window or release time is rejected" do
    for window <- [[tw_early: 5], [tw_late: 100], [release_time: 5]] do
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client([required: false, is_break: true] ++ window)
        |> Model.add_vehicle_type(num_available: 1, capacity: [0])
        |> Model.set_euclidean_matrices([{0, 0}, {0, 0}])

      assert_raise ArgumentError, ~r/break clients must not have a time window or release time/, fn ->
        Model.to_problem_data(model)
      end
    end
  end

  test "breaks are left out of every neighbourhood" do
    neighbours = Native.build_neighbours_nif(problem_data())

    assert Enum.at(neighbours, @break) == []
    refute Enum.any?(neighbours, &(@break in &1))
    assert Enum.at(neighbours, 1) == [2, 4]
  end
end

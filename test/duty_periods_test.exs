defmodule ExVrp.DutyPeriodsTest do
  @moduledoc """
  Duty periods: the time between two rests, held to an `ExVrp.DutyRule`'s
  `:max_duty`, and the driving in each, held to its `:max_drive`.

  The stored routes run a square of 250 a side: depot (0, 0), A (250, 0),
  B (250, 250), C (0, 250), each client served for 30. Driving all of it is
  1000, on duty 1090: one period too long and too much driving for the limits
  of 780 and 540, two that fit when a rest splits it at B. Client 4 is a rest
  placed by hand, client 5 a break. A window on A pins the start, where the
  tests need waiting the start cannot slide away.
  """
  use ExUnit.Case, async: true

  alias ExVrp.DutyRule
  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  @a 1
  @b 2
  @c 3
  @rest 4
  @break 5
  @service 30
  @rest_duration 660
  @max_duty 780
  @max_duty_drive 540
  @points [{0, 0}, {250, 0}, {250, 250}, {0, 250}, {5000, 0}, {6000, 0}]

  defp vehicle(vehicle_opts) do
    {rule_opts, vehicle_opts} = Keyword.pop(vehicle_opts, :rule, [])

    Keyword.merge(
      [
        num_available: 2,
        capacity: [0],
        unit_distance_cost: 0,
        unit_duration_cost: 1,
        max_drive_between_breaks: 10_000,
        break_duration: 45,
        duty_rule: duty_rule(rule_opts)
      ],
      vehicle_opts
    )
  end

  defp duty_rule(rule_opts) do
    [rest_duration: @rest_duration, max_duty: @max_duty, max_drive: @max_duty_drive]
    |> Keyword.merge(rule_opts)
    |> DutyRule.new()
  end

  defp model(vehicle_opts \\ [], c_opts \\ []) do
    Model.new()
    |> Model.add_depot([])
    |> Model.add_client(service_duration: @service, tw_early: 0, tw_late: 250)
    |> Model.add_client(service_duration: @service)
    |> Model.add_client(Keyword.put(c_opts, :service_duration, @service))
    |> Model.add_client(required: false, is_break: true, is_rest: true)
    |> Model.add_client(required: false, is_break: true)
    |> Model.add_vehicle_type(vehicle(vehicle_opts))
    |> Model.set_euclidean_matrices(@points)
  end

  defp route(visits, vehicle_opts \\ [], c_opts \\ []) do
    {:ok, data} = vehicle_opts |> model(c_opts) |> Model.to_problem_data()
    {:ok, ref} = Native.create_solution_from_routes(data, [visits])
    %Solution{solution_ref: ref, routes: [visits]} |> Solution.routes() |> hd()
  end

  defp route_cost(route), do: route_cost(route, Native.search_route_empty_nif(route))

  defp route_cost(_route, true = _empty), do: 0

  defp route_cost(route, false = _empty) do
    Native.search_route_fixed_vehicle_cost_nif(route) + Native.search_route_distance_cost_nif(route) +
      Native.search_route_duration_cost_nif(route) + Native.search_route_time_warp_nif(route) +
      Native.search_route_excess_distance_nif(route)
  end

  describe "stored routes" do
    test "a route with no rest is one duty period, past both limits" do
      route = route([@a, @b, @c])

      assert Route.duty_excess(route) == 1090 - @max_duty + (1000 - @max_duty_drive)
      assert Route.time_warp(route) == Route.duty_excess(route)
    end

    test "a rest that splits the route into periods that fit leaves no excess" do
      route = route([@a, @b, @rest, @c])

      assert Route.duty_excess(route) == 0
      assert Route.time_warp(route) == 0
      assert Route.duration(route) == 1090 + @rest_duration
    end

    test "travel on a leg that holds a rest is driven after the rest" do
      route = route([@a, @rest, @b, @c])

      assert Route.duty_excess(route) == 280 + 530 - @max_duty + (750 - @max_duty_drive)
    end

    test "waiting before the first visit after a rest lengthens the rest" do
      route = route([@a, @b, @rest, @c], [], tw_early: 3000)

      assert Route.wait_duration(route) > 0
      assert Route.duty_excess(route) == 0
    end

    test "waiting between two visits of a period is duty" do
      plain = route([@a, @b, @c])
      waiting = route([@a, @b, @c], [], tw_early: 3000)

      assert Route.wait_duration(waiting) > 0
      assert Route.duty_excess(waiting) == Route.duty_excess(plain) + Route.wait_duration(waiting)
    end

    test "duty and driving before the route join its first period, duty after it its last" do
      assert Route.duty_excess(route([@a, @b, @rest, @c], rule: [duty_carry_in: 300])) == 560 + 300 - @max_duty
      assert Route.duty_excess(route([@a, @b, @rest, @c], rule: [drive_carry_in: 100])) == 500 + 100 - @max_duty_drive
      assert Route.duty_excess(route([@a, @b, @rest, @c], rule: [duty_after_end: 300])) == 530 + 300 - @max_duty
    end

    test "a break is duty, and does not end the period" do
      assert Route.duty_excess(route([@a, @b, @break, @c], rule: [max_drive: :infinity])) ==
               1090 + 45 - @max_duty
    end

    test "max_drive still bounds the whole route, across its rests" do
      route = route([@a, @b, @rest, @c], max_drive: 900)

      assert Route.duty_excess(route) == 0
      assert Route.drive_excess(route) == 100
    end

    test "breaks/1 tells a rest from a break" do
      pauses = Route.breaks(route([@a, @break, @b, @rest, @c]))

      assert Enum.map(pauses, & &1.rest?) == [false, true]
      assert Enum.map(pauses, &(&1.end_service - &1.start_service)) == [45, @rest_duration]
    end
  end

  describe "search routes" do
    test "the rests a route lacks are priced as virtual rests, not time warp" do
      {:ok, data} = Model.to_problem_data(model())
      search_route = Native.make_search_route_nif(data, [@a, @b, @c], 0, 0)

      assert Native.search_route_time_warp_nif(search_route) == 0

      assert Native.search_route_duration_nif(search_route) ==
               Route.duration(route([@a, @b, @c])) + @rest_duration
    end

    test "an empty route's carries join no period" do
      {:ok, data} = [rule: [duty_carry_in: 700, duty_after_end: 100]] |> model() |> Model.to_problem_data()
      search_route = Native.make_search_route_nif(data, [], 0, 0)

      assert Native.search_route_duration_nif(search_route) == 0
      assert Native.search_route_time_warp_nif(search_route) == 0
    end

    test "a search route with its rests in place prices them as the stored route does" do
      {:ok, data} = Model.to_problem_data(model())
      search_route = Native.make_search_route_nif(data, [@a, @b, @rest, @c], 0, 0)

      assert Native.search_route_time_warp_nif(search_route) == 0
      assert Native.search_route_duration_nif(search_route) == Route.duration(route([@a, @b, @rest, @c]))
    end

    for {name, from, to, u_idx, v_idx} <- [
          {"a client into a route with a rest", [@c], [@a, @b, @rest], 1, 3},
          {"a client out of a route with a rest", [@a, @b, @rest, @c], [], 4, 0},
          {"a client across a rest within its period", [@a, @rest, @b, @c], [], 1, 0},
          {"a rest onto another route", [@a, @rest, @b], [@c], 2, 1}
        ] do
      test "moving #{name} is priced exactly" do
        {:ok, data} = Model.to_problem_data(model())
        {:ok, evaluator} = Native.create_cost_evaluator(load_penalties: [0.0], tw_penalty: 1.0, dist_penalty: 1.0)

        from_visits = unquote(from)
        to_visits = unquote(to) -- from_visits
        route1 = Native.make_search_route_nif(data, from_visits, 0, 0)
        route2 = Native.make_search_route_nif(data, to_visits, 1, 0)
        before = route_cost(route1) + route_cost(route2)

        op = Native.create_exchange10_nif(data)
        u = Native.search_route_get_node_nif(route1, unquote(u_idx))
        v = Native.search_route_get_node_nif(route2, unquote(v_idx))
        delta = Native.exchange10_evaluate_nif(op, u, v, evaluator)

        :ok = Native.exchange10_apply_nif(op, u, v)
        Native.search_route_update_nif(route1)
        Native.search_route_update_nif(route2)

        assert delta == route_cost(route1) + route_cost(route2) - before
      end
    end
  end

  describe "every improving move" do
    @second_rest 6
    @sweep_points @points ++ [{7000, 0}]

    defp sweep_data do
      first = vehicle(rule: [duty_carry_in: 120, drive_carry_in: 60, duty_after_end: 40])

      second =
        vehicle(rule: [rest_duration: 600, max_duty: 700, max_drive: 480, drive_carry_in: 60, duty_after_end: 90])

      {:ok, data} =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(service_duration: @service)
        |> Model.add_client(service_duration: @service, tw_early: 900, tw_late: 5000)
        |> Model.add_client(service_duration: @service)
        |> Model.add_client(required: false, is_break: true, is_rest: true)
        |> Model.add_client(required: false, is_break: true)
        |> Model.add_client(required: false, is_break: true, is_rest: true)
        |> Model.add_vehicle_type(first)
        |> Model.add_vehicle_type(second)
        |> Model.set_euclidean_matrices(@sweep_points)
        |> Model.to_problem_data()

      data
    end

    defp operator(:exchange10),
      do: {&Native.create_exchange10_nif/1, &Native.exchange10_evaluate_nif/4, &Native.exchange10_apply_nif/3}

    defp operator(:exchange20),
      do: {&Native.create_exchange20_nif/1, &Native.exchange20_evaluate_nif/4, &Native.exchange20_apply_nif/3}

    defp operator(:exchange21),
      do: {&Native.create_exchange21_nif/1, &Native.exchange21_evaluate_nif/4, &Native.exchange21_apply_nif/3}

    defp operator(:swap_tails),
      do: {&Native.create_swap_tails_nif/1, &Native.swap_tails_evaluate_nif/4, &Native.swap_tails_apply_nif/3}

    defp improving_move_mismatches(name, {visits1, visits2}, u_idx, v_idx) do
      {create, evaluate, apply} = operator(name)
      data = sweep_data()
      {:ok, evaluator} = Native.create_cost_evaluator(load_penalties: [0.0], tw_penalty: 1.0, dist_penalty: 1.0)

      route1 = Native.make_search_route_nif(data, visits1, 0, 0)
      route2 = Native.make_search_route_nif(data, visits2, 1, 1)
      before = route_cost(route1) + route_cost(route2)

      op = create.(data)
      u = Native.search_route_get_node_nif(route1, u_idx)
      v = Native.search_route_get_node_nif(route2, v_idx)

      improving_move_mismatch(evaluate.(op, u, v, evaluator), op, u, v, apply, {route1, route2}, before)
    end

    defp improving_move_mismatch(delta, _op, _u, _v, _apply, _routes, _before) when delta >= 0, do: []

    defp improving_move_mismatch(delta, op, u, v, apply, {route1, route2}, before) do
      :ok = apply.(op, u, v)
      Native.search_route_update_nif(route1)
      Native.search_route_update_nif(route2)

      case route_cost(route1) + route_cost(route2) - before do
        ^delta -> []
        applied -> [{delta, applied}]
      end
    end

    test "is priced exactly, across rests, breaks, carries and vehicle types" do
      route_pairs = [
        {[@a, @b, @rest, @c], []},
        {[@a, @rest, @b], [@c]},
        {[@rest, @a, @b], [@c]},
        {[@a, @b, @c, @rest], []},
        {[@a, @break, @b, @rest, @c], []},
        {[@a, @rest, @second_rest, @b], [@c]},
        {[@a, @rest, @b, @second_rest, @c], []},
        {[@b, @c], [@a, @rest]},
        {[@c, @rest], [@a, @second_rest, @b]},
        {[@a, @rest, @break, @second_rest, @b], [@c]},
        {[@break, @rest, @a, @b], [@c, @second_rest]},
        {[@a, @second_rest, @b, @break], [@rest, @c]},
        {[@rest, @second_rest, @a], [@b, @c]}
      ]

      mismatches =
        for name <- [:exchange10, :exchange20, :exchange21, :swap_tails],
            {visits1, visits2} = routes <- route_pairs,
            u_idx <- 1..length(visits1),
            v_idx <- 0..length(visits2),
            mismatch <- improving_move_mismatches(name, routes, u_idx, v_idx),
            do: {name, routes, u_idx, v_idx, mismatch}

      assert mismatches == []
    end
  end

  describe "pool" do
    test "a vehicle without a shift gets breaks for each duty period, not the cap for each" do
      {:ok, data} = Model.to_problem_data(model())
      breaks_per_period = div(@max_duty_drive + 10_000 - 1, 10_000) + 1
      periods_per_vehicle = 14 + 1

      assert length(Native.problem_data_break_clients(data)) == 1 + 2 * periods_per_vehicle * breaks_per_period
    end
  end

  describe "break repair" do
    test "a break that pushes a period past max_duty gets the rest that fixes it" do
      vehicle_opts = [num_available: 1, max_drive_between_breaks: 900, rule: [max_duty: 1100, max_drive: :infinity]]
      {:ok, data} = vehicle_opts |> model() |> Model.to_problem_data()
      {:ok, seed} = Native.create_solution_from_routes(data, [[@a, @b, @c]])
      {:ok, evaluator} = Native.create_cost_evaluator(load_penalties: [0.0], tw_penalty: 1000.0, dist_penalty: 1.0)

      {:ok, ref} = Native.local_search_search_only(seed, data, evaluator)
      [route] = Solution.routes(%Solution{solution_ref: ref, routes: Native.solution_routes(ref)})

      assert Route.clock_excess(route) == 0
      assert Route.duty_excess(route) == 0
      assert Enum.any?(Route.breaks(route), & &1.rest?)
    end
  end

  describe "solving" do
    @day 1440

    defp ring_model(num_clients, radius, horizon_days) do
      points =
        for idx <- 0..(num_clients - 1) do
          angle = 2 * :math.pi() * idx / num_clients
          {round(radius * :math.cos(angle)), round(radius * :math.sin(angle))}
        end

      vehicle = [
        num_available: 1,
        capacity: [0],
        unit_distance_cost: 1,
        unit_duration_cost: 1,
        time_windows: [{0, horizon_days * @day}],
        shift_duration: horizon_days * @day,
        max_drive_between_breaks: 270,
        break_duration: 45,
        duty_rule: duty_rule([])
      ]

      points
      |> Enum.reduce(Model.add_depot(Model.new(), []), fn _point, model ->
        Model.add_client(model, service_duration: 60)
      end)
      |> Model.add_vehicle_type(vehicle)
      |> Model.set_euclidean_matrices([{0, 0} | points])
    end

    defp solve(model) do
      {:ok, result} = Solver.solve(model, stop: StoppingCriteria.max_iterations(400), num_starts: 1, seed: 1)
      result.best
    end

    defp duty_periods(route) do
      [{_depot, _trip, start, _end, _wait, _tw} | _rest] = Route.schedule(route)
      rests = Enum.filter(Route.breaks(route), & &1.rest?)
      bounds = [start | Enum.flat_map(rests, &[&1.start_service, &1.end_service])] ++ [Route.end_time(route)]

      bounds |> Enum.chunk_every(2) |> Enum.map(fn [from, to] -> to - from end)
    end

    test "a route of several days' work gets the rests that keep every duty period legal" do
      solution = 8 |> ring_model(300, 6) |> solve()
      [route] = Solution.routes(solution)

      assert Solution.feasible?(solution)
      assert length(Route.visits(route)) == 8
      assert Route.duty_excess(route) == 0
      assert Route.clock_excess(route) == 0

      periods = duty_periods(route)
      assert length(periods) >= 3
      assert Enum.all?(periods, &(&1 <= @max_duty))
    end

    test "rests come back as rests, each lasting the rest duration" do
      [route] = 8 |> ring_model(300, 6) |> solve() |> Solution.routes()
      rests = Enum.filter(Route.breaks(route), & &1.rest?)

      assert rests != []
      assert Enum.all?(rests, &(&1.end_service - &1.start_service == @rest_duration))
    end

    test "a route that fits one duty period takes no rest" do
      [route] = 4 |> ring_model(60, 4) |> solve() |> Solution.routes()

      assert Route.duty_excess(route) == 0
      refute Enum.any?(Route.breaks(route), & &1.rest?)
    end

    test "work that does not fit the horizon once rested is infeasible" do
      refute 8 |> ring_model(300, 2) |> solve() |> Solution.feasible?()
    end

    test "a warm start marks each rest :rest, so a changed model resumes it as a rest" do
      model = ring_model(8, 300, 6)
      {:ok, [visits]} = model |> solve() |> Solution.warm_start()
      [vehicle_type] = model.vehicle_types
      changed = %{model | vehicle_types: [%{vehicle_type | num_available: 2}]}

      {:ok, resumed} =
        Solver.solve(changed, initial_routes: [visits], stop: StoppingCriteria.max_iterations(0), num_starts: 1)

      [route] = Solution.routes(resumed.best)
      num_rests = Enum.count(visits, &(&1 == :rest))

      assert num_rests > 0
      assert Enum.all?(visits, &(&1 in [:break, :rest] or &1 in 1..8))
      assert Enum.count(Route.breaks(route), & &1.rest?) == num_rests
    end
  end

  describe "validation" do
    defp validation_errors(vehicle_opts) do
      {:error, errors} = vehicle_opts |> model() |> Model.validate()
      errors
    end

    test "a duty limit must be positive or :infinity" do
      assert Enum.any?(validation_errors(rule: [max_duty: 0]), &(&1 =~ "max_duty and max_drive must be positive"))
    end

    test "a duty limit needs a rest duration" do
      assert Enum.any?(validation_errors(rule: [rest_duration: 0]), &(&1 =~ "needs a positive rest_duration"))
    end

    test "a duty limit needs a break limit" do
      errors = validation_errors(max_drive_between_breaks: :infinity, break_duration: 0)

      assert Enum.any?(errors, &(&1 =~ "needs a positive rest_duration"))
    end

    test "a rest duration must be an integer" do
      assert Enum.any?(validation_errors(rule: [rest_duration: :infinity]), &(&1 =~ "rest_duration"))

      assert Enum.any?(
               validation_errors(shift_duration: 2000, rule: [rest_duration: :infinity]),
               &(&1 =~ "rest_duration")
             )
    end

    test "a duty rule must be an ExVrp.DutyRule" do
      errors = validation_errors(duty_rule: %{max_duty: @max_duty, rest_duration: @rest_duration})

      assert Enum.any?(errors, &(&1 =~ "must be nil or an ExVrp.DutyRule"))
    end

    test "a carry that alone overruns its limit is rejected" do
      assert Enum.any?(validation_errors(rule: [duty_carry_in: @max_duty + 1]), &(&1 =~ "exceeds its limit"))
      assert Enum.any?(validation_errors(rule: [drive_carry_in: @max_duty_drive + 1]), &(&1 =~ "exceeds its limit"))
    end
  end
end

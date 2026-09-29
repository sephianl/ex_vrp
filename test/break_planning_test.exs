defmodule ExVrp.BreakPlanningTest do
  @moduledoc """
  The model adds a pool of break clients for every vehicle type with a break
  rule, and local search places them: `BreakRepair` inserts a break where a
  stretch first overruns and removes breaks that cost nothing to lose.

  Unless a test says otherwise, a vehicle type leaves `unit_duration_cost` at
  0, so a break that fixes nothing costs nothing to remove and is removed.
  Break time is what `duration` holds beyond travel, service and waiting.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  @rule %{max_drive_between_breaks: 270, duration: 45}

  # Depot 0 and clients at 150, 300 and 450 on a line (1 unit = 1 s of drive).
  defp model(vehicle_opts) do
    Model.new()
    |> Model.add_depot([])
    |> Model.add_client(delivery: [1])
    |> Model.add_client(delivery: [1])
    |> Model.add_client(delivery: [1])
    |> Model.add_vehicle_type(Keyword.merge([num_available: 1, capacity: [10]], vehicle_opts))
    |> Model.set_euclidean_matrices([{0, 0}, {150, 0}, {300, 0}, {450, 0}])
  end

  defp best(model, solve_opts \\ []) do
    {:ok, result} =
      Solver.solve(model, Keyword.merge([stop: StoppingCriteria.max_iterations(500), num_starts: 1], solve_opts))

    result.best
  end

  defp break_time(route) do
    Route.duration(route) - Route.travel_duration(route) - Route.service_duration(route) - Route.wait_duration(route)
  end

  # Depot 0 and one client at 150: out and back drives 300.
  defp one_client_model(client_opts, vehicle_opts) do
    Model.new()
    |> Model.add_depot([])
    |> Model.add_client(Keyword.merge([delivery: [1]], client_opts))
    |> Model.add_vehicle_type(Keyword.merge([num_available: 1, capacity: [10]], vehicle_opts))
    |> Model.set_euclidean_matrices([{0, 0}, {150, 0}])
  end

  defp client_start(solution, client) do
    [visit] = solution |> Solution.route_schedule(0) |> Enum.filter(&(&1.location == client))
    visit.start_service - Route.start_time(hd(Solution.routes(solution)))
  end

  # Out and back is 900 of drive, three times one 270 limit: at least three breaks.
  test "the solver inserts the breaks the clock needs and the plan is feasible" do
    solution = [break_rule: @rule] |> model() |> best()
    [route] = Solution.routes(solution)

    assert Solution.feasible?(solution)
    assert Route.clock_excess(route) == 0
    assert Enum.sort(Route.visits(route)) == [1, 2, 3]
    assert rem(break_time(route), 45) == 0
    assert break_time(route) >= 3 * 45
  end

  test "without a break rule nothing changes" do
    solution = [] |> model() |> best()
    [route] = Solution.routes(solution)

    assert Solution.num_clients(solution) == 3
    assert break_time(route) == 0
  end

  test "callers never see the break clients" do
    solution = [break_rule: @rule] |> model() |> best()
    [route] = Solution.routes(solution)

    assert Solution.num_clients(solution) == 3
    assert Solution.unassigned(solution) == []
    assert Enum.sort(route.visits) == [1, 2, 3]
    assert Enum.sort(Solution.route_visits(solution, 0)) == [1, 2, 3]
    assert solution |> Solution.route_schedule(0) |> Enum.map(& &1.location) |> Enum.sort() == [0, 0, 1, 2, 3]
  end

  # Capacity 2 per vehicle and three unit deliveries: both vehicles must drive.
  # Only the ruled type has a break duration, so a break on the ruleless route
  # would cost nothing and fix nothing, and must not stay there.
  test "a vehicle type without a rule never carries a break" do
    solution =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(delivery: [1])
      |> Model.add_client(delivery: [1])
      |> Model.add_client(delivery: [1])
      |> Model.add_vehicle_type(num_available: 1, capacity: [2], break_rule: @rule)
      |> Model.add_vehicle_type(num_available: 1, capacity: [2])
      |> Model.set_euclidean_matrices([{0, 0}, {150, 0}, {300, 0}, {450, 0}])
      |> best()

    routes = Solution.routes(solution)
    assert length(routes) == 2
    assert Solution.feasible?(solution)

    [ruleless] = Enum.filter(routes, &(&1.vehicle_type == 1))
    assert break_time(ruleless) == 0
    assert Solution.num_clients(solution) == 3
  end

  # One client at 100: out and back drives 200 < 270, so the warm-started
  # break (client 2, the first of the pool) fixes nothing. Duration is priced
  # here, so the plan without it is strictly cheaper: the warm start is the
  # first best, and only a strict improvement replaces it.
  test "an unnecessary break is removed" do
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(delivery: [1])
      |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_duration_cost: 1, break_rule: @rule)
      |> Model.set_euclidean_matrices([{0, 0}, {100, 0}])

    solution = best(model, initial_routes: [[1, 2]])
    [route] = Solution.routes(solution)

    assert Route.visits(route) == [1]
    assert break_time(route) == 0
    assert Route.clock_excess(route) == 0
  end

  # One client at 600, so each leg drives 600. Under the search's rule a leg
  # with k breaks leaves 600 - (k - 1) * 270 after its reset: k = 2 leaves 330
  # (overrun), k = 3 leaves 60. So 3 per leg, 6 in all: 6 * 45 = 270 of break.
  test "a leg longer than twice the limit gets enough breaks" do
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(delivery: [1])
      |> Model.add_vehicle_type(num_available: 1, capacity: [10], break_rule: @rule)
      |> Model.set_euclidean_matrices([{0, 0}, {600, 0}])

    solution = best(model)
    [route] = Solution.routes(solution)

    assert Solution.feasible?(solution)
    assert Route.clock_excess(route) == 0
    assert break_time(route) == 6 * 45
  end

  # Work is 150 + 200 service + 150 = 500 against a 400 limit, while driving
  # is only 300. The one break that works goes after the service: before the
  # client, the stretch after it would still hold 500.
  test "the work clock alone makes the solver insert a break" do
    solution =
      [service_duration: 200] |> one_client_model(break_rule: %{max_work_between_breaks: 400, duration: 45}) |> best()

    [route] = Solution.routes(solution)

    assert Solution.feasible?(solution)
    assert Route.work_clock_excess(route) == 0
    assert break_time(route) == 45
    assert client_start(solution, 1) == 150

    drive_only =
      [service_duration: 200] |> one_client_model(break_rule: %{max_drive_between_breaks: 400, duration: 45}) |> best()

    assert drive_only |> Solution.routes() |> hd() |> break_time() == 0
  end

  # Without a carry, 150 + 150 overruns 270 on the way back: one break there.
  # A carry of 150 overruns on the way out, so a break comes before the client,
  # and the whole 300 after it needs a second one.
  for {carry, limit} <- [drive_carry_in: :max_drive_between_breaks, work_carry_in: :max_work_between_breaks] do
    test "#{carry} brings the first break a leg earlier" do
      rule = %{unquote(limit) => 270, duration: 45}

      fresh = [] |> one_client_model(break_rule: rule) |> best()
      assert fresh |> Solution.routes() |> hd() |> break_time() == 45
      assert client_start(fresh, 1) == 150

      carried = [] |> one_client_model([{unquote(carry), 150}, break_rule: rule]) |> best()
      [route] = Solution.routes(carried)

      assert Solution.feasible?(carried)
      assert Route.clock_excess(route) + Route.work_clock_excess(route) == 0
      assert break_time(route) == 90
      assert client_start(carried, 1) == 195
    end
  end

  # 300 of work fits a 350 limit; 100 more after the last stop does not.
  test "work_after_end counts against the last stretch" do
    rule = %{max_work_between_breaks: 350, duration: 45}

    assert [] |> one_client_model(break_rule: rule) |> best() |> Solution.routes() |> hd() |> break_time() == 0

    solution = [] |> one_client_model(break_rule: rule, work_after_end: 100) |> best()
    [route] = Solution.routes(solution)

    assert Solution.feasible?(solution)
    assert Route.work_clock_excess(route) == 0
    assert break_time(route) == 45
  end

  # 0 -> 1 -> 2 -> 0 drives 100 + 100 + 150 = 350. Client 1 closes at 100, so
  # the route starts at 0, and client 2 opens at 400, so it waits there. A
  # break on the last leg would add 45; one on 1 -> 2 leaves 100 + 150 after
  # it, fits, and comes out of the wait.
  test "a break on an earlier leg absorbs waiting" do
    matrix = [[0, 100, 150], [100, 0, 100], [150, 100, 0]]

    model = fn vehicle_opts ->
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(delivery: [1], tw_late: 100)
      |> Model.add_client(delivery: [1], tw_early: 400)
      |> Model.add_vehicle_type(Keyword.merge([num_available: 1, capacity: [10], unit_duration_cost: 1], vehicle_opts))
      |> Model.set_distance_matrices([matrix])
      |> Model.set_duration_matrices([matrix])
    end

    [plain] = [] |> model.() |> best() |> Solution.routes()
    solution = [break_rule: @rule] |> model.() |> best()
    [route] = Solution.routes(solution)

    assert Solution.feasible?(solution)
    assert Route.clock_excess(route) == 0
    assert break_time(route) == 45
    assert Route.duration(plain) == 550
    assert Route.duration(route) == 550
    assert Route.wait_duration(route) == Route.wait_duration(plain) - 45
  end

  # Capacity 1 and two unit deliveries: two trips, 400 of drive across them.
  test "a two-trip route gets the breaks it needs" do
    solution =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(delivery: [1])
      |> Model.add_client(delivery: [1])
      |> Model.add_vehicle_type(num_available: 1, capacity: [1], reload_depots: [0], break_rule: @rule)
      |> Model.set_euclidean_matrices([{0, 0}, {100, 0}, {-100, 0}])
      |> best()

    [route] = Solution.routes(solution)

    assert Solution.feasible?(solution)
    assert Solution.num_clients(solution) == 2
    assert Route.num_trips(route) == 2
    assert Route.clock_excess(route) == 0
    assert break_time(route) >= 45
  end

  # The route runs past 500, so it meets the vehicle's 500-600 gap.
  test "breaks and a forbidden window go together" do
    solution = [break_rule: @rule, time_windows: [{0, 500}, {600, 100_000}]] |> model() |> best()
    [route] = Solution.routes(solution)

    assert Solution.feasible?(solution)
    assert Solution.num_clients(solution) == 3
    assert Route.clock_excess(route) == 0
    assert break_time(route) >= 3 * 45
  end

  test "a warm start leaves the breaks out" do
    solution = [break_rule: @rule] |> model() |> best()

    assert {:ok, [visits]} = Solution.warm_start(solution)
    assert Enum.sort(visits) == [1, 2, 3]
  end

  # Breaks are optional clients, but a random start never takes one: only
  # local search places them. Trips keep breaks, so they would show there.
  test "a random solution carries no breaks" do
    {:ok, problem_data} = [break_rule: @rule] |> model() |> Model.to_problem_data()

    for seed <- 1..20 do
      {:ok, solution} = ExVrp.Native.create_random_solution(problem_data, seed: seed)

      visits = solution |> ExVrp.Native.solution_trips() |> List.flatten() |> Enum.flat_map(& &1.clients)
      assert Enum.sort(visits) == [1, 2, 3]
    end
  end

  # 8 per vehicle at most: max_drive and shift_duration are both unset.
  test "the pool holds enough breaks per vehicle, after every user client" do
    {:ok, problem_data} = [break_rule: @rule, num_available: 2] |> model() |> Model.to_problem_data()

    assert ExVrp.Native.problem_data_num_clients(problem_data) == 3 + 2 * 8
  end

  # max_drive 900 over a 270 limit: ceil(900 / 270) = 4 breaks per vehicle.
  test "max_drive sizes the pool" do
    {:ok, problem_data} = [break_rule: @rule, max_drive: 900] |> model() |> Model.to_problem_data()

    assert ExVrp.Native.problem_data_num_clients(problem_data) == 3 + 4
  end
end

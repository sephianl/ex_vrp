defmodule ExVrp.BreakPlanningTest do
  @moduledoc """
  The model adds a pool of break clients for every vehicle type with a break
  rule, and local search places them: `BreakRepair` inserts a break where a
  stretch first overruns and removes breaks that cost nothing to lose.

  Every vehicle type here leaves `unit_duration_cost` at 0 and sets no time
  windows, so a break costs nothing but its duration, and nothing waits:
  `duration - travel_duration` is exactly the break time on the route.
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

  defp break_time(route), do: Route.duration(route) - Route.travel_duration(route)

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

defmodule ExVrp.MaxDriveTest do
  @moduledoc """
  Tests for `:max_drive`, the cap on wheels-turning time.

  `:max_duration` caps elapsed time, so a driver who waits two hours at a dock
  has spent two hours of it. `:max_drive` counts only the edges driven, which is
  what a legal driving-time limit measures.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  # Depot at 0 and two clients at 30 and 60 on a line, one vehicle, so the only
  # route is 0 -> 30 -> 60 -> 0: 120 of driving. Client 1 closes at 40, which
  # pins the departure to before 10; client 2 opens at 500, so the route must
  # wait ~440 there — a later departure cannot hide it. Every cap below sits
  # between the drive (120) and the elapsed duration (~560), so which clock
  # bites is forced.
  defp model(vehicle_opts) do
    Model.new()
    |> Model.add_depot([])
    |> Model.add_client(delivery: [1], tw_early: 0, tw_late: 40)
    |> Model.add_client(delivery: [1], tw_early: 500, tw_late: 10_000)
    |> Model.add_vehicle_type(Keyword.merge([num_available: 1, capacity: [10]], vehicle_opts))
    |> Model.set_euclidean_matrices([{0, 0}, {30, 0}, {60, 0}])
  end

  defp best(vehicle_opts) do
    {:ok, result} = Solver.solve(model(vehicle_opts), stop: StoppingCriteria.max_iterations(200))
    result.best
  end

  test "waiting does not count as driving" do
    solution = best(max_drive: 200)
    [route] = Solution.routes(solution)

    assert Route.duration(route) > 200
    assert Route.drive_excess(route) == 0
    assert Solution.feasible?(solution)
  end

  test "driving past the cap is reported and counted as time warp" do
    solution = best(max_drive: 100)
    [route] = Solution.routes(solution)

    assert Route.travel_duration(route) == 120
    assert Route.drive_excess(route) == 20
    assert Route.time_warp(route) == 20
    refute Solution.feasible?(solution)

    # Drive excess is a penalty, not a shift along the timeline: here it is
    # the route's only time warp (time_warp == drive_excess), so end_time
    # must land exactly on start_time + duration, unmoved by the 20 units of
    # excess folded into time_warp.
    assert Route.end_time(route) == Route.start_time(route) + Route.duration(route)
  end

  test "an unset cap changes nothing" do
    [capped] = Solution.routes(best(max_drive: :infinity))
    [plain] = Solution.routes(best([]))

    assert Route.visits(capped) == Route.visits(plain)
    assert Route.time_warp(capped) == Route.time_warp(plain)
    assert Route.drive_excess(plain) == 0
  end

  test "a cap splits work across vehicles when one cannot drive it all" do
    {:ok, result} =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(delivery: [1])
      |> Model.add_client(delivery: [1])
      |> Model.add_vehicle_type(num_available: 2, capacity: [10], max_drive: 130, fixed_cost: 1)
      |> Model.set_euclidean_matrices([{0, 0}, {60, 0}, {-60, 0}])
      |> Solver.solve(stop: StoppingCriteria.max_iterations(300))

    assert Solution.feasible?(result.best)
    assert length(Solution.routes(result.best)) == 2
  end

  test "forbidden windows still add the drive excess" do
    forbidden_time_windows = [{0, 250}, {300, 20_000}]
    solution = best(max_drive: 100, time_windows: forbidden_time_windows)
    [route] = Solution.routes(solution)

    uncapped = best(max_drive: :infinity, time_windows: forbidden_time_windows)
    [uncapped_route] = Solution.routes(uncapped)

    assert Route.drive_excess(route) == 20
    # Drive excess is folded into time_warp on top of whatever the forbidden
    # window itself contributes, so subtracting it back out must land exactly
    # on the time warp of the same schedule solved without the cap — the cap
    # adds drive excess, nothing else.
    assert Route.time_warp(route) - Route.drive_excess(route) == Route.time_warp(uncapped_route)
  end

  test "a negative cap is rejected" do
    assert_raise ArgumentError, ~r/max_drive/, fn -> best(max_drive: -1) end
  end
end

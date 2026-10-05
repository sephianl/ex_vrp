defmodule ExVrp.MaxDriveTest do
  @moduledoc """
  Tests for `:max_drive`, the cap on wheels-turning time.

  `:max_duration` caps elapsed time, so a driver who waits two hours at a dock
  has spent two hours of it. `:max_drive` counts only the edges driven.

  The shared model puts the depot at 0 and two clients at 30 and 60 on a line,
  with one vehicle, so the only route is 0 -> 30 -> 60 -> 0: 120 of driving.
  Client 1 closes at 40, pinning the departure before 10; client 2 opens at
  500, so the route waits ~440 there and a later departure cannot hide it.
  Every cap sits between the drive (120) and the elapsed duration (~560), so
  which clock bites is forced.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

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

  defp two_trip_route(max_drive) do
    {:ok, result} =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(delivery: [1])
      |> Model.add_client(delivery: [1])
      |> Model.add_vehicle_type(num_available: 1, capacity: [1], reload_depots: [0], max_drive: max_drive)
      |> Model.set_euclidean_matrices([{0, 0}, {40, 0}, {-40, 0}])
      |> Solver.solve(stop: StoppingCriteria.max_iterations(200))

    [route] = Solution.routes(result.best)
    route
  end

  test "waiting does not count as driving" do
    solution = best(max_drive: 200)
    [route] = Solution.routes(solution)

    assert Route.duration(route) > 200
    assert Route.drive_excess(route) == 0
    assert Solution.feasible?(solution)
  end

  test "driving past the cap is reported and counted as time warp, without moving the end time" do
    solution = best(max_drive: 100)
    [route] = Solution.routes(solution)

    assert Route.travel_duration(route) == 120
    assert Route.drive_excess(route) == 20
    assert Route.time_warp(route) == 20
    assert Solution.drive_excess(solution) == 20
    refute Solution.feasible?(solution)
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

  test "the cap counts driving summed over trips, though each 80-unit trip is under it" do
    over = two_trip_route(120)

    assert Route.num_trips(over) == 2
    assert Route.travel_duration(over) == 160
    assert Route.drive_excess(over) == 40
    assert Route.time_warp(over) == 40
    assert Route.end_time(over) == Route.start_time(over) + Route.duration(over)

    assert Route.drive_excess(two_trip_route(160)) == 0
  end

  test "forbidden windows add their own time warp and the cap adds exactly the drive excess" do
    forbidden_time_windows = [{0, 250}, {300, 20_000}]
    [capped] = Solution.routes(best(max_drive: 100, time_windows: forbidden_time_windows))
    [uncapped] = Solution.routes(best(max_drive: :infinity, time_windows: forbidden_time_windows))

    assert Route.drive_excess(capped) == 20
    assert Route.time_warp(capped) - Route.drive_excess(capped) == Route.time_warp(uncapped)
  end

  test "a negative cap is rejected" do
    assert_raise ArgumentError, ~r/max_drive/, fn -> best(max_drive: -1) end
  end
end

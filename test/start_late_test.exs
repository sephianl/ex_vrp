defmodule ExVrp.StartLateTest do
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @durations [[0, 10], [10, 0]]

  defp model(vehicle_options) do
    Model.new()
    |> Model.add_depot(tw_early: 0, tw_late: 10_000)
    |> Model.add_client(delivery: [1], tw_early: 1_000, tw_late: 2_000)
    |> Model.add_vehicle_type(
      [num_available: 1, capacity: [10], time_windows: [{0, 10_000}], unit_duration_cost: 1] ++ vehicle_options
    )
    |> Model.set_distance_matrices([@durations])
    |> Model.set_duration_matrices([@durations])
  end

  defp only_route(model) do
    {:ok, result} = Solver.solve(model, stop: StoppingCriteria.max_iterations(200))
    [route] = Solution.routes(result.best)
    route
  end

  test "without a latest start the route starts as late as its first stop allows" do
    route = only_route(model([]))

    assert Route.start_time(route) == 990
    assert Route.wait_duration(route) == 0
  end

  test "a latest start at the window's start makes the route start then and count its waiting" do
    route = only_route(model(start_late: 0))

    assert Route.start_time(route) == 0
    assert Route.wait_duration(route) == 990
    assert Route.duration(route) == 1_010
  end
end

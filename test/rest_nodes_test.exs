defmodule ExVrp.RestNodesTest do
  @moduledoc """
  A rest client is a break client that lasts its vehicle type's rest
  duration instead of its break duration. Client 3 is a break, client 4 a
  rest; both have matrix rows far away so that any lookup that reads them
  shows up as extra distance.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  @break 3
  @rest 4
  @break_duration 45
  @rest_duration 660
  @points [{0, 0}, {10, 0}, {30, 0}, {1000, 0}, {2000, 0}]

  defp model(vehicle_opts) do
    vehicle =
      Keyword.merge(
        [
          num_available: 1,
          capacity: [0],
          unit_distance_cost: 1,
          unit_duration_cost: 1,
          rest_duration: @rest_duration
        ],
        vehicle_opts
      )

    Model.new()
    |> Model.add_depot([])
    |> Model.add_client([])
    |> Model.add_client([])
    |> Model.add_client(required: false, is_break: true)
    |> Model.add_client(required: false, is_break: true, is_rest: true)
    |> Model.add_vehicle_type(vehicle)
    |> Model.add_vehicle_type(Keyword.put(vehicle, :rest_duration, 2 * @rest_duration))
    |> Model.set_euclidean_matrices(@points)
  end

  defp route(visits, vehicle_opts \\ []) do
    {:ok, problem_data} = vehicle_opts |> model() |> Model.to_problem_data()
    {:ok, ref} = Native.create_solution_from_routes(problem_data, [visits])
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
    test "a rest between two clients costs no distance and adds the rest duration" do
      plain = route([1, 2])
      rested = route([1, @rest, 2])

      assert Route.distance(rested) == Route.distance(plain)
      assert Route.travel_duration(rested) == Route.travel_duration(plain)
      assert Route.duration(rested) == Route.duration(plain) + @rest_duration
    end

    test "a rest lasts the rest duration while a break lasts the break duration" do
      vehicle = [max_drive_between_breaks: 1_000, break_duration: @break_duration]
      plain = route([1, 2], vehicle)

      assert Route.duration(route([1, @break, 2], vehicle)) == Route.duration(plain) + @break_duration
      assert Route.duration(route([1, @rest, 2], vehicle)) == Route.duration(plain) + @rest_duration
    end

    test "a rest closes the drive clock like a break" do
      vehicle = [max_drive_between_breaks: 20, break_duration: @break_duration]
      with_rest = Route.clock_excess(route([1, @rest, 2], vehicle))

      assert with_rest == Route.clock_excess(route([1, @break, 2], vehicle))
      assert with_rest < Route.clock_excess(route([1, 2], vehicle))
    end

    test "a rest and a break on one leg both count towards the leg" do
      vehicle = [max_drive_between_breaks: 20, break_duration: @break_duration]

      assert Route.clock_excess(route([1, @break, @rest, 2], vehicle)) <
               Route.clock_excess(route([1, @break, 2], vehicle))

      assert Route.duration(route([1, @break, @rest, 2], vehicle)) ==
               Route.duration(route([1, 2], vehicle)) + @break_duration + @rest_duration
    end
  end

  describe "search routes" do
    test "a search route prices a rest as the stored route does" do
      {:ok, data} = [] |> model() |> Model.to_problem_data()
      search_route = Native.make_search_route_nif(data, [1, @rest, 2], 0, 0)

      assert Native.search_route_duration_nif(search_route) == Route.duration(route([1, 2])) + @rest_duration
    end

    test "moving a rest to another vehicle type's route takes that type's rest duration" do
      {:ok, data} = [] |> model() |> Model.to_problem_data()
      {:ok, evaluator} = Native.create_cost_evaluator(load_penalties: [0.0], tw_penalty: 1.0, dist_penalty: 1.0)

      route1 = Native.make_search_route_nif(data, [1, @rest], 0, 0)
      route2 = Native.make_search_route_nif(data, [2], 1, 1)
      before = route_cost(route1) + route_cost(route2)

      op = Native.create_exchange10_nif(data)
      u = Native.search_route_get_node_nif(route1, 2)
      v = Native.search_route_get_node_nif(route2, 1)
      delta = Native.exchange10_evaluate_nif(op, u, v, evaluator)

      :ok = Native.exchange10_apply_nif(op, u, v)
      Native.search_route_update_nif(route1)
      Native.search_route_update_nif(route2)

      assert delta == route_cost(route1) + route_cost(route2) - before
      assert Native.search_route_duration_nif(route2) == Route.duration(route([2])) + 2 * @rest_duration
    end
  end

  describe "break repair" do
    test "never places a rest client as a break" do
      vehicle = [max_drive_between_breaks: 20, break_duration: @break_duration]

      {:ok, result} =
        vehicle
        |> model()
        |> Solver.solve(stop: StoppingCriteria.max_iterations(200), num_starts: 1, seed: 1)

      breaks = result.best |> Solution.routes() |> Enum.flat_map(&Route.breaks/1)

      assert length(breaks) >= 2
      assert Enum.all?(breaks, &(&1.end_service - &1.start_service == @break_duration))
    end
  end

  describe "validation" do
    test "a rest client must be a break client" do
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(required: false, is_rest: true)
        |> Model.add_vehicle_type(num_available: 1, capacity: [0])
        |> Model.set_euclidean_matrices([{0, 0}, {1, 0}])

      assert_raise ArgumentError, ~r/rest clients must be break clients/, fn ->
        Model.to_problem_data(model)
      end
    end

    test "a negative rest duration is rejected" do
      assert_raise ArgumentError, ~r/rest_duration must be >= 0/, fn ->
        [rest_duration: -1] |> model() |> Model.to_problem_data()
      end
    end
  end
end

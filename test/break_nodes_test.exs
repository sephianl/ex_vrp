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

  defp model(opts) do
    Model.new()
    |> Model.add_depot([])
    |> Model.add_client(tw_window(opts[:client_1_tw]))
    |> Model.add_client(tw_window(opts[:client_2_tw]))
    |> Model.add_client(required: false, service_duration: @break_duration, is_break: true)
    |> Model.add_client([])
    |> Model.add_vehicle_type(
      [num_available: 2, capacity: [0], unit_distance_cost: 1, unit_duration_cost: 1] ++ Keyword.get(opts, :vehicle, [])
    )
    |> Model.set_euclidean_matrices([{0, 0}, {10, 0}, {30, 0}, {1000, 0}, {0, 50}])
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
      travel: Route.travel_duration(route)
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

    defp route_cost(route) do
      Native.search_route_distance_cost_nif(route) + Native.search_route_duration_cost_nif(route) +
        Native.search_route_time_warp_nif(route) + Native.search_route_excess_distance_nif(route)
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
      route2 = Native.make_search_route_nif(data, visits2, 1, 0)
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

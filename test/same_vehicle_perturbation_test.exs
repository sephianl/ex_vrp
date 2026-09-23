defmodule ExVrp.SameVehiclePerturbationTest do
  @moduledoc """
  How perturbation treats a feasible route whose clients all belong to one same-vehicle group.

  The model is a day that is already planned: every vehicle drives a feasible warm-started route,
  and every route is one same-vehicle group, so its clients may only move together. On top of that
  plan come orders nobody has placed yet, each with a prize that dwarfs any detour. There is room
  for them, but only if the routes shift around them.

  Runs split into "nothing placed" and "nearly everything placed". A search that perturbs group
  members off those routes lands on "nothing placed" almost every time. Leaving a group member on a
  feasible route in place turns those removals into insertions of the unplaced orders, and a fair
  share of runs then gets them in. Why the removals trap the search is not established; this pins
  the measured effect, not a mechanism.
  """

  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.PenaltyManager
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  @num_vehicles 12
  @stops_per_route 14
  @num_new_orders 60
  @depot {500, 500}
  @service_duration 10
  @arrival_tolerance 90
  @shift_slack 600
  @prize 3_333_300_000

  # The claim is about what the search reliably does, not what one lucky seed did, so it is asserted
  # over a spread of them.
  @seeds 1..10

  @penalty_params %PenaltyManager.Params{
    min_penalty: 2_222.2,
    max_penalty: 333_330_000_000.0
  }

  defp planned_day do
    routes = Enum.map(0..(@num_vehicles - 1), &planned_route/1)
    held_clients = Enum.flat_map(routes, fn {stops, _finish} -> Enum.map(stops, &held_client/1) end)
    new_orders = Enum.map(1..@num_new_orders, &new_order/1)
    clients = held_clients ++ new_orders

    Model.new()
    |> Model.add_depot([])
    |> add_clients(clients)
    |> add_vehicles(routes)
    |> Model.set_euclidean_matrices([@depot | Enum.map(clients, &elem(&1, 0))])
    |> hold_each_route_to_its_vehicle()
  end

  defp planned_route(vehicle) do
    angle = 2 * :math.pi() * vehicle / @num_vehicles
    centre = {500 + 250 * :math.cos(angle), 500 + 250 * :math.sin(angle)}

    centre
    |> scattered_stops(vehicle)
    |> nearest_neighbour_tour()
    |> timed_from_depot()
  end

  defp scattered_stops({x, y}, vehicle) do
    for stop <- 1..@stops_per_route do
      {round(x + jitter({vehicle, stop, :x})), round(y + jitter({vehicle, stop, :y}))}
    end
  end

  defp jitter(key), do: :erlang.phash2(key, 160) - 80

  defp nearest_neighbour_tour(stops) do
    {tour, _position} =
      Enum.map_reduce(1..length(stops), {@depot, stops}, fn _step, {here, remaining} ->
        next = Enum.min_by(remaining, &distance(here, &1))
        {next, {next, List.delete(remaining, next)}}
      end)

    tour
  end

  defp timed_from_depot(tour) do
    {timed, {last, time}} =
      Enum.map_reduce(tour, {@depot, 0}, fn stop, {here, time} ->
        arrival = time + distance(here, stop)
        {{stop, arrival}, {stop, arrival + @service_duration}}
      end)

    {timed, time + distance(last, @depot)}
  end

  defp distance({x1, y1}, {x2, y2}), do: round(:math.sqrt((x1 - x2) ** 2 + (y1 - y2) ** 2))

  defp held_client({location, arrival}) do
    {location,
     [
       delivery: [6],
       prize: @prize,
       required: false,
       service_duration: @service_duration,
       tw_early: max(arrival - @arrival_tolerance, 0),
       tw_late: arrival + @arrival_tolerance
     ]}
  end

  defp new_order(order) do
    location = {:erlang.phash2({order, :x}, 1000), :erlang.phash2({order, :y}, 1000)}

    {location,
     [delivery: [2], prize: @prize, required: false, service_duration: @service_duration, tw_early: 0, tw_late: 2_000]}
  end

  defp add_clients(model, clients) do
    Enum.reduce(clients, model, fn {_location, client}, acc -> Model.add_client(acc, client) end)
  end

  defp add_vehicles(model, routes) do
    routes
    |> Enum.with_index()
    |> Enum.reduce(model, fn {{_stops, finish}, vehicle}, acc ->
      Model.add_vehicle_type(acc,
        num_available: 1,
        capacity: [100],
        name: "vehicle #{vehicle}",
        time_windows: [{0, finish + @shift_slack}]
      )
    end)
  end

  defp hold_each_route_to_its_vehicle(model) do
    Enum.reduce(0..(@num_vehicles - 1), model, fn vehicle, acc ->
      Model.add_same_vehicle_group(acc, Enum.to_list(held_client_indices(vehicle)))
    end)
  end

  defp held_client_indices(vehicle), do: (vehicle * @stops_per_route)..((vehicle + 1) * @stops_per_route - 1)

  defp planned_routes do
    for vehicle <- 0..(@num_vehicles - 1), do: Enum.map(held_client_indices(vehicle), &(&1 + 1))
  end

  defp new_orders_placed(model, seed) do
    {:ok, %{best: best}} =
      ExVrp.solve(model,
        stop: StoppingCriteria.max_iterations(2_000),
        seed: seed,
        num_starts: 1,
        penalty_params: @penalty_params,
        initial_routes: planned_routes()
      )

    true = Solution.feasible?(best)

    best
    |> Solution.routes()
    |> Enum.flat_map(&Route.visits/1)
    |> Enum.count(&(&1 > @num_vehicles * @stops_per_route))
  end

  test "new orders get placed around a fully held plan on a fair share of seeds" do
    model = planned_day()

    placed = for seed <- @seeds, do: new_orders_placed(model, seed)

    assert Enum.count(placed, &(&1 > 0)) >= 3
  end
end

defmodule ExVrp.VehicleProfileTest do
  @moduledoc """
  Tests for multiple distance/duration matrix profiles.

  Verifies that different vehicle types can use different profiles
  (distance/duration matrices), producing correct vehicle-client assignments
  based on their respective travel costs.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver

  defp solve(model, opts \\ []) do
    stop = Keyword.get(opts, :stop, ExVrp.StoppingCriteria.max_iterations(1000))
    Solver.solve(model, stop: stop)
  end

  describe "multiple vehicle profiles" do
    test "two profiles with different matrices produce correct vehicle-client assignments" do
      # Profile 0 (bicycle): fast to client 2, slow to client 1
      # Profile 1 (car): fast to client 1, slow to client 2
      # Each vehicle should be assigned to the client it can reach cheaply.
      bicycle_matrix = [
        [0, 100, 1],
        [100, 0, 100],
        [1, 100, 0]
      ]

      car_matrix = [
        [0, 1, 100],
        [1, 0, 100],
        [100, 100, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_late: 500)
        |> Model.add_client(
          x: 1,
          y: 0,
          delivery: [10],
          service_duration: 10,
          tw_early: 0,
          tw_late: 500,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 2,
          y: 0,
          delivery: [10],
          service_duration: 10,
          tw_early: 0,
          tw_late: 500,
          required: false,
          prize: 100_000
        )
        # Bicycle uses profile 0
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 0,
          tw_late: 500,
          profile: 0,
          name: "bicycle"
        )
        # Car uses profile 1
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 0,
          tw_late: 500,
          profile: 1,
          name: "car"
        )
        |> Model.set_duration_matrices([bicycle_matrix, car_matrix])
        |> Model.set_distance_matrices([bicycle_matrix, car_matrix])

      {:ok, result} = solve(model)

      assert Solution.feasible?(result.best)
      assert Solution.complete?(result.best)
      assert Solution.num_clients(result.best) == 2

      routes = Solution.routes(result.best)
      assert length(routes) == 2

      # Each route: depot->client->depot with cost 1 each way = distance 2
      route_distances = routes |> Enum.map(&Route.distance/1) |> Enum.sort()
      assert route_distances == [2, 2]
    end

    test "single vehicle uses correct profile matrix" do
      # Only a car (profile 1) - should use the car matrix for routing
      bicycle_matrix = [
        [0, 100, 100, 100, 100],
        [100, 0, 100, 100, 100],
        [100, 100, 0, 100, 100],
        [100, 100, 100, 0, 100],
        [100, 100, 100, 100, 0]
      ]

      car_matrix = [
        [0, 10, 10, 10, 10],
        [10, 0, 10, 10, 10],
        [10, 10, 0, 10, 10],
        [10, 10, 10, 0, 10],
        [10, 10, 10, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_late: 500)
        |> Model.add_client(
          x: 1,
          y: 0,
          delivery: [10],
          service_duration: 10,
          tw_early: 0,
          tw_late: 500,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 2,
          y: 0,
          delivery: [10],
          service_duration: 10,
          tw_early: 0,
          tw_late: 500,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 3,
          y: 0,
          delivery: [10],
          service_duration: 10,
          tw_early: 0,
          tw_late: 500,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 4,
          y: 0,
          delivery: [10],
          service_duration: 10,
          tw_early: 0,
          tw_late: 500,
          required: false,
          prize: 100_000
        )
        # Car uses profile 1
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 0,
          tw_late: 500,
          profile: 1,
          name: "car"
        )
        |> Model.set_duration_matrices([bicycle_matrix, car_matrix])
        |> Model.set_distance_matrices([bicycle_matrix, car_matrix])

      {:ok, result} = solve(model)

      assert Solution.feasible?(result.best)
      assert Solution.complete?(result.best)

      # Car uses car_matrix (10 per leg), 4 clients = 5 legs = 50
      routes = Solution.routes(result.best)
      assert length(routes) == 1
      [route] = routes
      assert Route.distance(route) == 50
    end

    test "route distances match expected profile matrix" do
      # Two vehicles, each visiting exactly one client using different profiles.
      # Use separate time windows to force one client per vehicle.
      matrix_cheap = [
        [0, 10, 10],
        [10, 0, 10],
        [10, 10, 0]
      ]

      matrix_expensive = [
        [0, 100, 100],
        [100, 0, 100],
        [100, 100, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_late: 1000)
        # Client 1: early time window, only cheap vehicle (profile 0) is available then
        |> Model.add_client(
          x: 1,
          y: 0,
          delivery: [10],
          service_duration: 10,
          tw_early: 0,
          tw_late: 100,
          required: false,
          prize: 100_000
        )
        # Client 2: late time window, only expensive vehicle (profile 1) is available then
        |> Model.add_client(
          x: 2,
          y: 0,
          delivery: [10],
          service_duration: 10,
          tw_early: 500,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        # Vehicle A uses cheap profile (0), only available early
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 0,
          tw_late: 100,
          profile: 0,
          name: "cheap"
        )
        # Vehicle B uses expensive profile (1), only available late
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          tw_early: 500,
          tw_late: 1000,
          profile: 1,
          name: "expensive"
        )
        |> Model.set_duration_matrices([matrix_cheap, matrix_expensive])
        |> Model.set_distance_matrices([matrix_cheap, matrix_expensive])

      {:ok, result} = solve(model)

      assert Solution.feasible?(result.best)
      assert Solution.complete?(result.best)

      routes = Solution.routes(result.best)
      assert length(routes) == 2

      route_distances = routes |> Enum.map(&Route.distance/1) |> Enum.sort()

      # Cheap route: depot->client->depot = 10+10 = 20
      # Expensive route: depot->client->depot = 100+100 = 200
      assert route_distances == [20, 200]
    end
  end
end

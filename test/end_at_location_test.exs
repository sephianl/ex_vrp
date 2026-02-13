defmodule ExVrp.EndAtLocationTest do
  @moduledoc """
  Tests for vehicles ending at custom locations (not depot).
  Ported from zelo's routing_end_at_location_test.exs
  """

  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  describe "end_depot functionality" do
    test "vehicle ends at specified location" do
      # ExVRP location order: [depot0, depot1, client0, client1, client2]
      # So we need a 5x5 matrix for 2 depots + 3 clients
      duration_matrix = [
        # depot0, depot1, c0, c1, c2
        [0, 10, 20, 30, 40],
        [10, 0, 10, 20, 30],
        [20, 10, 0, 10, 20],
        [30, 20, 10, 0, 10],
        [40, 30, 20, 10, 0]
      ]

      model =
        Model.new()
        # Main depot at index 0
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        # End depot at index 1
        |> Model.add_depot(x: 1, y: 0, tw_early: 0, tw_late: 1000)
        # Clients at indices 2, 3, 4
        |> Model.add_client(x: 2, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 3, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 4, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          start_depot: 0,
          end_depot: 1,
          tw_early: 0,
          tw_late: 1000
        )
        |> Model.set_distance_matrices([duration_matrix])
        |> Model.set_duration_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, stop: StoppingCriteria.max_iterations(1000))

      assert result.best
      assert Solution.complete?(result.best)

      routes = Solution.routes(result.best)
      assert length(routes) == 1

      [route] = routes
      # Route should start at depot 0 and end at depot 1
      assert route.start_depot == 0,
             "Expected start_depot 0, got #{route.start_depot}"

      assert route.end_depot == 1,
             "Expected end_depot 1, got #{route.end_depot}. Route: #{inspect(route)}"
    end

    test "two vehicles at same end depot" do
      # 2 depots + 3 clients = 5 locations
      duration_matrix = [
        [0, 10, 20, 30, 40],
        [10, 0, 10, 20, 30],
        [20, 10, 0, 10, 20],
        [30, 20, 10, 0, 10],
        [40, 30, 20, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        |> Model.add_depot(x: 1, y: 0, tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 2, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 3, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 4, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_vehicle_type(
          num_available: 2,
          capacity: [20],
          start_depot: 0,
          end_depot: 1,
          tw_early: 0,
          tw_late: 1000
        )
        |> Model.set_distance_matrices([duration_matrix])
        |> Model.set_duration_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, stop: StoppingCriteria.max_iterations(1000))

      assert result.best
      assert Solution.complete?(result.best)

      routes = Solution.routes(result.best)
      # Both vehicles should end at depot 1
      for route <- routes do
        assert route.start_depot == 0

        assert route.end_depot == 1,
               "Expected end_depot 1, got #{route.end_depot}. Route: #{inspect(route)}"
      end
    end

    test "two vehicles at different end depots" do
      # 3 depots + 3 clients = 6 locations
      duration_matrix = [
        [0, 10, 20, 30, 40, 50],
        [10, 0, 10, 20, 30, 40],
        [20, 10, 0, 10, 20, 30],
        [30, 20, 10, 0, 10, 20],
        [40, 30, 20, 10, 0, 10],
        [50, 40, 30, 20, 10, 0]
      ]

      model =
        Model.new()
        # Main depot at index 0
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        # End depot 1 at index 1
        |> Model.add_depot(x: 1, y: 0, tw_early: 0, tw_late: 1000)
        # End depot 2 at index 2
        |> Model.add_depot(x: 2, y: 0, tw_early: 0, tw_late: 1000)
        # Clients at indices 3, 4, 5
        |> Model.add_client(x: 3, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 4, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 5, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        # Vehicle type 0: ends at depot 1
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [20],
          start_depot: 0,
          end_depot: 1,
          tw_early: 0,
          tw_late: 1000
        )
        # Vehicle type 1: ends at depot 2
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [20],
          start_depot: 0,
          end_depot: 2,
          tw_early: 0,
          tw_late: 1000
        )
        |> Model.set_distance_matrices([duration_matrix])
        |> Model.set_duration_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, stop: StoppingCriteria.max_iterations(1000))

      assert result.best
      assert Solution.complete?(result.best)

      routes = Solution.routes(result.best)
      # Should have routes from both vehicle types
      assert routes != []

      # Verify each route ends at its assigned depot
      for route <- routes do
        assert route.start_depot == 0
        # end_depot should be 1 or 2 depending on vehicle type
        assert route.end_depot in [1, 2],
               "Expected end_depot in [1, 2], got #{route.end_depot}. Route: #{inspect(route)}"
      end
    end

    test "vehicle ending at depot returns to depot" do
      # 1 depot + 4 clients = 5 locations
      duration_matrix = [
        [0, 10, 20, 30, 40],
        [10, 0, 10, 20, 30],
        [20, 10, 0, 10, 20],
        [30, 20, 10, 0, 10],
        [40, 30, 20, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 1, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 2, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 3, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 4, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          start_depot: 0,
          end_depot: 0,
          tw_early: 0,
          tw_late: 1000
        )
        |> Model.set_distance_matrices([duration_matrix])
        |> Model.set_duration_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, stop: StoppingCriteria.max_iterations(1000))

      assert result.best
      assert Solution.complete?(result.best)

      routes = Solution.routes(result.best)
      assert length(routes) == 1

      [route] = routes
      # Should start and end at depot 0
      assert route.start_depot == 0
      assert route.end_depot == 0
    end

    test "mixed vehicles with and without custom end depot" do
      # 2 depots + 3 clients = 5 locations
      duration_matrix = [
        [0, 10, 20, 30, 40],
        [10, 0, 10, 20, 30],
        [20, 10, 0, 10, 20],
        [30, 20, 10, 0, 10],
        [40, 30, 20, 10, 0]
      ]

      model =
        Model.new()
        # Main depot at index 0
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        # End depot at index 1
        |> Model.add_depot(x: 1, y: 0, tw_early: 0, tw_late: 1000)
        # Clients at indices 2, 3, 4
        |> Model.add_client(x: 2, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 3, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 4, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        # Vehicle type 0: returns to main depot
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [20],
          start_depot: 0,
          end_depot: 0,
          tw_early: 0,
          tw_late: 1000
        )
        # Vehicle type 1: ends at depot 1
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [20],
          start_depot: 0,
          end_depot: 1,
          tw_early: 0,
          tw_late: 1000
        )
        |> Model.set_distance_matrices([duration_matrix])
        |> Model.set_duration_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, stop: StoppingCriteria.max_iterations(1000))

      assert result.best
      assert Solution.complete?(result.best)

      routes = Solution.routes(result.best)

      # Each route should end at its assigned depot
      for route <- routes do
        assert route.start_depot == 0

        assert route.end_depot in [0, 1],
               "Expected end_depot in [0, 1], got #{route.end_depot}. Route: #{inspect(route)}"
      end
    end

    test "multiple runs with same seed produce consistent results" do
      # 2 depots + 3 clients = 5 locations
      duration_matrix = [
        [0, 10, 20, 30, 40],
        [10, 0, 10, 20, 30],
        [20, 10, 0, 10, 20],
        [30, 20, 10, 0, 10],
        [40, 30, 20, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        |> Model.add_depot(x: 1, y: 0, tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 2, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 3, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_client(x: 4, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [20],
          start_depot: 0,
          end_depot: 0,
          tw_early: 0,
          tw_late: 1000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [20],
          start_depot: 0,
          end_depot: 1,
          tw_early: 0,
          tw_late: 1000
        )
        |> Model.set_distance_matrices([duration_matrix])
        |> Model.set_duration_matrices([duration_matrix])

      # Run multiple times with the same seed
      results =
        for seed <- [42, 42, 42] do
          {:ok, result} = Solver.solve(model, stop: StoppingCriteria.max_iterations(500), seed: seed)
          result.best.routes
        end

      # All results should be identical (same seed = same output)
      [first | rest] = results

      for other <- rest do
        assert first == other, "Results with same seed should be identical"
      end
    end
  end
end

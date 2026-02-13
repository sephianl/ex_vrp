defmodule ExVrp.MultiDimensionalCapacityTest do
  @moduledoc """
  Tests for multiple capacity dimensions (e.g., weight, volume, pallet space).

  Verifies that the solver correctly handles multi-dimensional capacity
  constraints, including independent dimensions, cross-dimension overflow,
  and scaling to many dimensions.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solution
  alias ExVrp.Solver

  defp solve(model, opts \\ []) do
    stop = Keyword.get(opts, :stop, ExVrp.StoppingCriteria.max_iterations(1000))
    Solver.solve(model, stop: stop)
  end

  describe "multiple dimensions" do
    test "two clients on different dimensions fit in one trip" do
      # Client 1: fills pallet dimension (3 of 3)
      # Client 2: fills rolco dimension (6 of 6)
      # They use completely independent dimensions, so they fit together
      matrix = [[0, 1, 1], [1, 0, 1], [1, 1, 0]]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_late: 1000, service_duration: 10)
        |> Model.add_client(
          x: 1,
          y: 0,
          delivery: [0, 0],
          pickup: [3, 0],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 2,
          y: 0,
          delivery: [0, 0],
          pickup: [0, 6],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [3, 6],
          tw_early: 0,
          tw_late: 1000
        )
        |> Model.set_duration_matrices([matrix])
        |> Model.set_distance_matrices([matrix])

      {:ok, result} = solve(model)

      assert Solution.feasible?(result.best)
      assert Solution.complete?(result.best)
      assert Solution.num_clients(result.best) == 2

      # Both fit in a single trip since they use independent dimensions
      routes = Solution.routes(result.best)
      assert length(routes) == 1
    end

    test "overflow in one dimension drops client despite other dimension having space" do
      matrix = [[0, 1], [1, 0]]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_late: 1000)
        |> Model.add_client(
          x: 1,
          y: 0,
          delivery: [1, 10],
          pickup: [0, 0],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [3, 6],
          tw_early: 0,
          tw_late: 1000
        )
        |> Model.set_duration_matrices([matrix])
        |> Model.set_distance_matrices([matrix])

      {:ok, result} = solve(model)

      assert Solution.feasible?(result.best)
      assert Solution.num_clients(result.best) == 0
    end

    test "multi-trip triggered by overflow across multiple dimensions" do
      # Capacity: pallet=3, rolco=6, container=9
      # Client 1: pallet=2
      # Client 2: container=7
      # Client 3: rolco=4
      # Client 4: pallet=2, rolco=4
      # Combined: pallet=4>3, rolco=8>6 — can't fit in one trip
      matrix = [[0, 1, 1, 1, 1], [1, 0, 1, 1, 1], [1, 1, 0, 1, 1], [1, 1, 1, 0, 1], [1, 1, 1, 1, 0]]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_late: 1000, service_duration: 10)
        |> Model.add_client(
          x: 1,
          y: 0,
          delivery: [0, 0, 0],
          pickup: [2, 0, 0],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 2,
          y: 0,
          delivery: [0, 0, 0],
          pickup: [0, 0, 7],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 3,
          y: 0,
          delivery: [0, 0, 0],
          pickup: [0, 4, 0],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 4,
          y: 0,
          delivery: [0, 0, 0],
          pickup: [2, 4, 0],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [3, 6, 9],
          reload_depots: [0],
          max_reloads: :infinity,
          tw_early: 0,
          tw_late: 1000
        )
        |> Model.set_duration_matrices([matrix])
        |> Model.set_distance_matrices([matrix])

      {:ok, result} = solve(model)

      assert Solution.feasible?(result.best)
      assert Solution.complete?(result.best)
      assert Solution.num_clients(result.best) == 4

      routes = Solution.routes(result.best)
      assert length(routes) == 1
      [route] = routes
      assert ExVrp.Route.num_trips(route) >= 2
    end

    test "single dimension bottleneck forces multi-trip while others have room" do
      # Capacity: pallet=2, rolco=100, container=100
      # Client 1: pickup [2, 1, 1] — fills pallet completely
      # Client 2: pickup [2, 1, 1] — fills pallet completely
      # Combined pallet=4>2, but rolco=2<<100 and container=2<<100
      # Pallet dimension alone forces multi-trip
      matrix = [[0, 1, 1], [1, 0, 1], [1, 1, 0]]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_late: 1000, service_duration: 10)
        |> Model.add_client(
          x: 1,
          y: 0,
          delivery: [0, 0, 0],
          pickup: [2, 1, 1],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 2,
          y: 0,
          delivery: [0, 0, 0],
          pickup: [2, 1, 1],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [2, 100, 100],
          reload_depots: [0],
          max_reloads: :infinity,
          tw_early: 0,
          tw_late: 1000
        )
        |> Model.set_duration_matrices([matrix])
        |> Model.set_distance_matrices([matrix])

      {:ok, result} = solve(model)

      assert Solution.feasible?(result.best)
      assert Solution.complete?(result.best)
      assert Solution.num_clients(result.best) == 2

      routes = Solution.routes(result.best)
      assert length(routes) == 1
      [route] = routes
      assert ExVrp.Route.num_trips(route) == 2
    end

    test "50 capacity dimensions scales correctly" do
      matrix = [[0, 1], [1, 0]]
      num_types = 50

      capacity = List.duplicate(5, num_types)

      # Demand: alternating 1 pickup and 1 delivery across dimensions
      pickup = for i <- 0..(num_types - 1), do: if(rem(i, 2) == 0, do: 1, else: 0)
      delivery = for i <- 0..(num_types - 1), do: if(rem(i, 2) == 1, do: 1, else: 0)

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_late: 5000)
        |> Model.add_client(
          x: 1,
          y: 0,
          delivery: delivery,
          pickup: pickup,
          service_duration: 5,
          tw_early: 0,
          tw_late: 5000,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: capacity,
          tw_early: 0,
          tw_late: 10_000
        )
        |> Model.set_duration_matrices([matrix])
        |> Model.set_distance_matrices([matrix])

      {:ok, result} = solve(model)

      assert Solution.feasible?(result.best)
      assert Solution.complete?(result.best)
      assert Solution.num_clients(result.best) == 1
    end
  end
end

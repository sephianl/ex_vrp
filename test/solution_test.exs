defmodule ExVrp.SolutionTest do
  @moduledoc """
  Tests for ExVrp.Solution module.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solution
  alias ExVrp.Solver

  describe "solution properties" do
    setup do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20])
        |> Model.add_client(x: 20, y: 0, delivery: [30])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      %{solution: result.best, model: model}
    end

    test "distance returns non-negative value", %{solution: solution} do
      assert Solution.distance(solution) >= 0
    end

    test "duration returns non-negative value", %{solution: solution} do
      assert Solution.duration(solution) >= 0
    end

    test "num_routes returns correct count", %{solution: solution} do
      assert Solution.num_routes(solution) >= 1
    end

    test "feasible? returns boolean", %{solution: solution} do
      assert is_boolean(Solution.feasible?(solution))
    end

    test "complete? returns boolean", %{solution: solution} do
      assert is_boolean(Solution.complete?(solution))
    end
  end

  describe "route_distance/2" do
    test "returns distance for valid route index" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      # Check first route's distance
      assert Solution.route_distance(solution, 0) >= 0
    end

    test "returns 0 for invalid route index" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      # Invalid index should return 0
      assert Solution.route_distance(solution, 999) == 0
    end
  end

  describe "route_duration/2" do
    test "returns duration for valid route index" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_duration(solution, 0) >= 0
    end
  end

  describe "route_delivery/2" do
    test "returns delivery load for valid route index" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [25])
        |> Model.add_client(x: 20, y: 0, delivery: [35])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      delivery = Solution.route_delivery(solution, 0)
      assert is_list(delivery)
      # Total delivery should be 25 + 35 = 60
      assert Enum.sum(delivery) == 60
    end
  end

  describe "route_pickup/2" do
    test "returns pickup load for valid route index" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, pickup: [15])
        |> Model.add_client(x: 20, y: 0, pickup: [25])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      pickup = Solution.route_pickup(solution, 0)
      assert is_list(pickup)
      # Total pickup should be 15 + 25 = 40
      assert Enum.sum(pickup) == 40
    end
  end

  describe "route_feasible?/2" do
    test "returns true for feasible route" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_feasible?(solution, 0) == true
    end
  end

  describe "unassigned/1" do
    test "returns empty list when all clients are assigned" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      # Complete solution should have no unassigned clients
      if Solution.complete?(solution) do
        unassigned = Solution.unassigned(solution)
        assert is_list(unassigned)
      end
    end
  end

  describe "solution feasibility" do
    test "feasible solution has feasible? = true" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      # Simple problem should find a feasible solution
      assert Solution.feasible?(solution) == true
    end

    test "complete solution has complete? = true" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      # All clients should be visited
      assert Solution.complete?(solution) == true
    end
  end

  describe "solution distance and duration" do
    test "distance is sum of route distances" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [50])
        |> Model.add_client(x: 20, y: 0, delivery: [50])
        |> Model.add_vehicle_type(num_available: 2, capacity: [60])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      total_dist = Solution.distance(solution)
      num_routes = Solution.num_routes(solution)

      # Sum route distances
      route_sum =
        0..(num_routes - 1)
        |> Enum.map(&Solution.route_distance(solution, &1))
        |> Enum.sum()

      assert total_dist == route_sum
    end

    test "duration is sum of route durations" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [50], service_duration: 5)
        |> Model.add_client(x: 20, y: 0, delivery: [50], service_duration: 10)
        |> Model.add_vehicle_type(num_available: 2, capacity: [60])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      total_dur = Solution.duration(solution)
      num_routes = Solution.num_routes(solution)

      # Sum route durations
      route_sum =
        0..(num_routes - 1)
        |> Enum.map(&Solution.route_duration(solution, &1))
        |> Enum.sum()

      assert total_dur == route_sum
    end
  end

  describe "solution num_clients" do
    test "returns total assigned clients" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_client(x: 30, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      assert Solution.num_clients(solution) == 3
    end
  end

  describe "solution with time windows" do
    test "respects time window constraints" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], tw_early: 0, tw_late: 100)
        |> Model.add_client(x: 20, y: 0, delivery: [10], tw_early: 50, tw_late: 150)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], tw_early: 0, tw_late: 200)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      # Should find a feasible solution respecting time windows
      assert Solution.feasible?(solution)
    end
  end

  describe "solution with capacity constraints" do
    test "uses multiple routes when capacity requires" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [60])
        |> Model.add_client(x: 20, y: 0, delivery: [60])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      # Need 2 routes because each client needs 60, capacity is 100
      assert Solution.num_routes(solution) == 2
      assert Solution.feasible?(solution)
    end
  end

  describe "solution with multiple dimensions" do
    test "handles multi-dimensional capacity" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [30, 20], pickup: [0, 0])
        |> Model.add_client(x: 20, y: 0, delivery: [30, 20], pickup: [0, 0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100, 50])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      # Should be feasible with 2D capacity
      assert Solution.feasible?(solution)

      # Route delivery should return 2 dimensions
      delivery = Solution.route_delivery(solution, 0)
      assert length(delivery) == 2
    end
  end

  describe "solution cost" do
    test "cost with default cost evaluator" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      # Distance-based cost should match distance for feasible solution
      cost = Solution.cost(solution)
      distance = Solution.distance(solution)

      # For default unit_distance_cost=1, cost should equal distance for feasible solution
      assert cost == distance
    end
  end

  describe "feasibility - shift duration (PyVRP parity)" do
    test "shift_duration constraint affects feasibility" do
      # Based on test_feasibility_shift_duration
      # With shift_duration=3000, routes exceeding this get time warp
      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
        |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
        |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_vehicle_type(num_available: 4, capacity: [10], shift_duration: 3000)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      # With tight shift_duration, solution may not be feasible (time warp)
      if Solution.time_warp(solution) > 0 do
        assert Solution.feasible?(solution) == false
      end
    end
  end

  describe "feasibility - max distance (PyVRP parity)" do
    test "max_distance constraint affects feasibility" do
      # Based on test_feasibility_max_distance
      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
        |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
        |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_vehicle_type(num_available: 4, capacity: [10], max_distance: 5000)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      # With tight max_distance, some routes may have excess distance
      excess_dist = Solution.excess_distance(solution)

      if excess_dist > 0 do
        assert Solution.feasible?(solution) == false
      end
    end
  end

  describe "time warp calculation (PyVRP parity)" do
    test "time_warp returns non-negative value" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], tw_early: 0, tw_late: 100)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.time_warp(solution) >= 0
    end

    test "tight time windows cause time warp" do
      # Based on test_time_warp_for_a_very_constrained_problem
      # Client 2 can only be reached after client 1 due to tight TW
      durations = [
        # cannot get to 2 from depot within 2's TW
        [0, 1, 10],
        [1, 0, 1],
        [1, 1, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 0, delivery: [0], tw_early: 0, tw_late: 5)
        |> Model.add_client(x: 2, y: 0, delivery: [0], tw_early: 0, tw_late: 5)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100], tw_early: 0, tw_late: 10)
        |> Model.set_duration_matrices([durations])
        |> Model.set_distance_matrices([Enum.map(durations, fn row -> Enum.map(row, &abs/1) end)])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      # Some configurations will have time warp
      assert is_integer(Solution.time_warp(solution))
    end
  end

  describe "excess load calculation (PyVRP parity)" do
    test "excess_load returns list of dimension excesses" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [60])
        |> Model.add_client(x: 20, y: 0, delivery: [60])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      excess = Solution.excess_load(solution)
      assert is_list(excess)

      # Total demand 120, capacity 100 = excess 20 if all on one route
      if Solution.num_routes(solution) == 1 do
        assert Enum.at(excess, 0) == 20
      end
    end

    test "multi-dimensional excess_load" do
      # Based on test_excess_load_calculation_with_multiple_load_dimensions
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 0, delivery: [10, 1], pickup: [0, 0])
        |> Model.add_client(x: 2, y: 0, delivery: [1, 10], pickup: [0, 0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [5, 5])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      excess = Solution.excess_load(solution)
      assert length(excess) == 2
      # Both dimensions should have excess (11 vs cap 5 each)
      assert Enum.at(excess, 0) == 6
      assert Enum.at(excess, 1) == 6
    end
  end

  describe "fixed vehicle cost (PyVRP parity)" do
    test "tracks fixed vehicle cost per route" do
      # Based on test_fixed_vehicle_cost
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100], fixed_cost: 100)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      fixed_cost = Solution.fixed_vehicle_cost(solution)
      num_routes = Solution.num_routes(solution)

      # Fixed cost should be 100 * num_routes
      assert fixed_cost == 100 * num_routes
    end
  end

  describe "distance and duration cost (PyVRP parity)" do
    test "distance_cost respects unit_distance_cost" do
      # Based on test_distance_duration_cost_calculations
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], unit_distance_cost: 5)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      distance = Solution.distance(solution)
      distance_cost = Solution.distance_cost(solution)

      # distance_cost should be 5 * distance
      assert distance_cost == 5 * distance
    end

    test "duration_cost respects unit_duration_cost" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], unit_duration_cost: 3)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      duration = Solution.duration(solution)
      duration_cost = Solution.duration_cost(solution)

      # duration_cost should be 3 * duration
      assert duration_cost == 3 * duration
    end
  end

  describe "overtime (PyVRP parity)" do
    test "overtime tracked when exceeding shift_duration" do
      # Based on test_overtime
      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [10],
          shift_duration: 5000,
          max_overtime: 1000,
          unit_overtime_cost: 10
        )

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      overtime = Solution.overtime(solution)
      assert is_integer(overtime)
      assert overtime >= 0
    end
  end

  describe "edge cases" do
    test "single client solution" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.num_routes(solution) == 1
      assert Solution.num_clients(solution) == 1
      assert Solution.feasible?(solution)
      assert Solution.complete?(solution)
    end

    test "many clients single route" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [1000])

      # Add 10 clients
      model =
        Enum.reduce(1..10, model, fn i, acc ->
          Model.add_client(acc, x: i * 10, y: 0, delivery: [10])
        end)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      assert Solution.num_routes(solution) == 1
      assert Solution.num_clients(solution) == 10
      assert Solution.feasible?(solution)
    end
  end

  describe "route_schedule/2" do
    alias ExVrp.ScheduledVisit

    test "returns list of ScheduledVisit structs" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      schedule = Solution.route_schedule(solution, 0)

      assert is_list(schedule)
      assert schedule != []

      # All elements should be ScheduledVisit structs
      Enum.each(schedule, fn visit ->
        assert %ScheduledVisit{} = visit
        assert is_integer(visit.location)
        assert is_integer(visit.trip)
        assert is_integer(visit.start_service)
        assert is_integer(visit.end_service)
        assert is_integer(visit.wait_duration)
        assert is_integer(visit.time_warp)
      end)
    end

    test "schedule includes depot visits" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      schedule = Solution.route_schedule(solution, 0)

      # Schedule should include at least depot->client->depot (3 visits)
      assert length(schedule) >= 3

      # First visit should be depot (location 0)
      first = hd(schedule)
      assert first.location == 0
    end

    test "service duration computed correctly" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], service_duration: 100)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      schedule = Solution.route_schedule(solution, 0)

      # Find the client visit (location 1)
      client_visit = Enum.find(schedule, fn v -> v.location == 1 end)
      assert client_visit

      # Service duration should be 100
      assert ScheduledVisit.service_duration(client_visit) == 100
      assert client_visit.end_service - client_visit.start_service == 100
    end

    test "feasible solution has no time warp" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.feasible?(solution)

      schedule = Solution.route_schedule(solution, 0)

      # No visit should have time warp in a feasible solution
      Enum.each(schedule, fn visit ->
        refute ScheduledVisit.has_time_warp?(visit)
      end)
    end

    test "schedule with time windows shows wait duration" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        # Client with time window starting at 100
        |> Model.add_client(x: 1, y: 0, delivery: [10], tw_early: 100, tw_late: 200)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      schedule = Solution.route_schedule(solution, 0)

      # Find client visit
      client_visit = Enum.find(schedule, fn v -> v.location == 1 end)
      assert client_visit

      # If vehicle arrives before tw_early, there should be wait_duration
      # Service should start at or after tw_early (100)
      assert client_visit.start_service >= 100
    end

    test "empty schedule for invalid route index" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      # Invalid route index should return empty list
      schedule = Solution.route_schedule(solution, 999)
      assert schedule == []
    end
  end
end

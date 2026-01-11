defmodule ExVrp.RouteTest do
  @moduledoc """
  Tests for ExVrp.Route module and route-related Solution functions.

  In ex_vrp, routes are accessed through Solution structs rather than
  being created directly from ProblemData. This mirrors PyVRP's test_Route.py.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver

  describe "route struct" do
    test "has expected fields" do
      route = %Route{}
      assert Map.has_key?(route, :visits)
      assert Map.has_key?(route, :vehicle_type)
      assert Map.has_key?(route, :start_depot)
      assert Map.has_key?(route, :end_depot)
      assert Map.has_key?(route, :trips)
      assert Map.has_key?(route, :solution_ref)
      assert Map.has_key?(route, :route_idx)
    end

    test "default values" do
      route = %Route{}
      assert route.visits == []
      assert route.vehicle_type == 0
      assert route.start_depot == 0
      assert route.end_depot == 0
      assert route.trips == []
      assert route.solution_ref == nil
      assert route.route_idx == nil
    end

    test "can be created with values" do
      route = %Route{visits: [1, 2, 3], vehicle_type: 1, start_depot: 0, end_depot: 0}
      assert route.visits == [1, 2, 3]
      assert route.vehicle_type == 1
    end

    test "num_clients returns length of visits" do
      route = %Route{visits: [1, 2, 3]}
      assert Route.num_clients(route) == 3

      empty_route = %Route{visits: []}
      assert Route.num_clients(empty_route) == 0
    end
  end

  describe "Solution.route/2 and Solution.routes/1" do
    setup do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20])
        |> Model.add_client(x: 20, y: 0, delivery: [30])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      %{solution: result.best}
    end

    test "Solution.route/2 returns Route struct", %{solution: solution} do
      route = Solution.route(solution, 0)
      assert %Route{} = route
    end

    test "Solution.route/2 populates solution_ref and route_idx", %{solution: solution} do
      route = Solution.route(solution, 0)
      assert route.solution_ref == solution.solution_ref
      assert route.route_idx == 0
    end

    test "Solution.routes/1 returns list of Route structs", %{solution: solution} do
      routes = Solution.routes(solution)
      assert is_list(routes)
      assert Enum.all?(routes, &match?(%Route{}, &1))
    end

    test "Solution.routes/1 populates solution_ref and route_idx", %{solution: solution} do
      routes = Solution.routes(solution)

      routes
      |> Enum.with_index()
      |> Enum.each(fn {route, idx} ->
        assert route.solution_ref == solution.solution_ref
        assert route.route_idx == idx
      end)
    end

    test "Route struct methods work with solution context", %{solution: solution} do
      route = Solution.route(solution, 0)

      # All these should work and return sensible values
      assert is_integer(Route.distance(route))
      assert is_integer(Route.duration(route))
      assert is_boolean(Route.feasible?(route))
      assert is_list(Route.delivery(route))
      assert is_list(Route.pickup(route))
    end
  end

  describe "Route struct methods (PyVRP parity)" do
    setup do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20], service_duration: 50, prize: 100)
        |> Model.add_client(x: 20, y: 0, delivery: [30], service_duration: 75, prize: 150)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      route = Solution.route(result.best, 0)
      %{route: route, solution: result.best}
    end

    test "Route.distance/1", %{route: route, solution: solution} do
      assert Route.distance(route) == Solution.route_distance(solution, 0)
    end

    test "Route.duration/1", %{route: route, solution: solution} do
      assert Route.duration(route) == Solution.route_duration(solution, 0)
    end

    test "Route.feasible?/1", %{route: route, solution: solution} do
      assert Route.feasible?(route) == Solution.route_feasible?(solution, 0)
    end

    test "Route.delivery/1", %{route: route, solution: solution} do
      assert Route.delivery(route) == Solution.route_delivery(solution, 0)
    end

    test "Route.pickup/1", %{route: route, solution: solution} do
      assert Route.pickup(route) == Solution.route_pickup(solution, 0)
    end

    test "Route.excess_load/1", %{route: route, solution: solution} do
      assert Route.excess_load(route) == Solution.route_excess_load(solution, 0)
    end

    test "Route.has_excess_load?/1", %{route: route, solution: solution} do
      assert Route.has_excess_load?(route) == Solution.route_has_excess_load?(solution, 0)
    end

    test "Route.time_warp/1", %{route: route, solution: solution} do
      assert Route.time_warp(route) == Solution.route_time_warp(solution, 0)
    end

    test "Route.has_time_warp?/1", %{route: route, solution: solution} do
      assert Route.has_time_warp?(route) == Solution.route_has_time_warp?(solution, 0)
    end

    test "Route.excess_distance/1", %{route: route, solution: solution} do
      assert Route.excess_distance(route) == Solution.route_excess_distance(solution, 0)
    end

    test "Route.has_excess_distance?/1", %{route: route, solution: solution} do
      assert Route.has_excess_distance?(route) == Solution.route_has_excess_distance?(solution, 0)
    end

    test "Route.overtime/1", %{route: route, solution: solution} do
      assert Route.overtime(route) == Solution.route_overtime(solution, 0)
    end

    test "Route.vehicle_type/1", %{route: route, solution: solution} do
      assert Route.vehicle_type(route) == Solution.route_vehicle_type(solution, 0)
    end

    test "Route.start_depot/1", %{route: route, solution: solution} do
      assert Route.start_depot(route) == Solution.route_start_depot(solution, 0)
    end

    test "Route.end_depot/1", %{route: route, solution: solution} do
      assert Route.end_depot(route) == Solution.route_end_depot(solution, 0)
    end

    test "Route.num_trips/1", %{route: route, solution: solution} do
      assert Route.num_trips(route) == Solution.route_num_trips(solution, 0)
    end

    test "Route.centroid/1", %{route: route, solution: solution} do
      assert Route.centroid(route) == Solution.route_centroid(solution, 0)
    end

    test "Route.start_time/1", %{route: route, solution: solution} do
      assert Route.start_time(route) == Solution.route_start_time(solution, 0)
    end

    test "Route.end_time/1", %{route: route, solution: solution} do
      assert Route.end_time(route) == Solution.route_end_time(solution, 0)
    end

    test "Route.slack/1", %{route: route, solution: solution} do
      assert Route.slack(route) == Solution.route_slack(solution, 0)
    end

    test "Route.service_duration/1", %{route: route, solution: solution} do
      assert Route.service_duration(route) == Solution.route_service_duration(solution, 0)
    end

    test "Route.travel_duration/1", %{route: route, solution: solution} do
      assert Route.travel_duration(route) == Solution.route_travel_duration(solution, 0)
    end

    test "Route.wait_duration/1", %{route: route, solution: solution} do
      assert Route.wait_duration(route) == Solution.route_wait_duration(solution, 0)
    end

    test "Route.distance_cost/1", %{route: route, solution: solution} do
      assert Route.distance_cost(route) == Solution.route_distance_cost(solution, 0)
    end

    test "Route.duration_cost/1", %{route: route, solution: solution} do
      assert Route.duration_cost(route) == Solution.route_duration_cost(solution, 0)
    end

    test "Route.prizes/1", %{route: route, solution: solution} do
      assert Route.prizes(route) == Solution.route_prizes(solution, 0)
    end

    test "Route.visits/1", %{route: route, solution: solution} do
      assert Route.visits(route) == Solution.route_visits(solution, 0)
    end

    test "Route.schedule/1", %{route: route} do
      schedule = Route.schedule(route)
      assert is_list(schedule)
    end
  end

  describe "route access via solution" do
    setup do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20])
        |> Model.add_client(x: 20, y: 0, delivery: [30])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      %{solution: result.best, model: model}
    end

    test "route distance is non-negative", %{solution: solution} do
      num_routes = Solution.num_routes(solution)

      for idx <- 0..(num_routes - 1) do
        assert Solution.route_distance(solution, idx) >= 0
      end
    end

    test "route duration is non-negative", %{solution: solution} do
      num_routes = Solution.num_routes(solution)

      for idx <- 0..(num_routes - 1) do
        assert Solution.route_duration(solution, idx) >= 0
      end
    end

    test "route delivery returns list", %{solution: solution} do
      delivery = Solution.route_delivery(solution, 0)
      assert is_list(delivery)
    end

    test "route pickup returns list", %{solution: solution} do
      pickup = Solution.route_pickup(solution, 0)
      assert is_list(pickup)
    end

    test "route feasible returns boolean", %{solution: solution} do
      assert is_boolean(Solution.route_feasible?(solution, 0))
    end
  end

  describe "route distance calculations" do
    test "total distance equals sum of route distances" do
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

      route_sum =
        0..(num_routes - 1)
        |> Enum.map(&Solution.route_distance(solution, &1))
        |> Enum.sum()

      assert total_dist == route_sum
    end

    test "empty route returns 0 distance for invalid index" do
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

  describe "route duration calculations" do
    test "total duration equals sum of route durations" do
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

      route_sum =
        0..(num_routes - 1)
        |> Enum.map(&Solution.route_duration(solution, &1))
        |> Enum.sum()

      assert total_dur == route_sum
    end

    test "route with service duration includes service time" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], service_duration: 100)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      duration = Solution.route_duration(solution, 0)
      # Duration should include at least the service time
      assert duration >= 100
    end
  end

  describe "route load calculations" do
    test "route delivery matches client deliveries" do
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

    test "route pickup matches client pickups" do
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

    test "multi-dimensional delivery" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [30, 20], pickup: [0, 0])
        |> Model.add_client(x: 20, y: 0, delivery: [30, 20], pickup: [0, 0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100, 50])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      delivery = Solution.route_delivery(solution, 0)
      assert length(delivery) == 2
      # First dimension: 30 + 30 = 60, Second dimension: 20 + 20 = 40
      assert Enum.at(delivery, 0) == 60
      assert Enum.at(delivery, 1) == 40
    end

    test "multi-dimensional pickup" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, pickup: [10, 5], delivery: [0, 0])
        |> Model.add_client(x: 20, y: 0, pickup: [15, 10], delivery: [0, 0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100, 50])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      pickup = Solution.route_pickup(solution, 0)
      assert length(pickup) == 2
      # First dimension: 10 + 15 = 25, Second dimension: 5 + 10 = 15
      assert Enum.at(pickup, 0) == 25
      assert Enum.at(pickup, 1) == 15
    end
  end

  describe "route feasibility" do
    test "feasible route has feasible? = true" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_feasible?(solution, 0) == true
    end

    test "all routes feasible in feasible solution" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [30])
        |> Model.add_client(x: 20, y: 0, delivery: [30])
        |> Model.add_vehicle_type(num_available: 2, capacity: [50])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      if Solution.feasible?(solution) do
        num_routes = Solution.num_routes(solution)

        for idx <- 0..(num_routes - 1) do
          assert Solution.route_feasible?(solution, idx) == true
        end
      end
    end
  end

  describe "single client route" do
    test "single client route properties" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.num_routes(solution) == 1
      assert Solution.route_distance(solution, 0) > 0
      assert Solution.route_feasible?(solution, 0)
    end
  end

  describe "multiple routes" do
    test "capacity forces multiple routes" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [60])
        |> Model.add_client(x: 20, y: 0, delivery: [60])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      # Each client needs 60 capacity, vehicle has 100
      # So need 2 routes
      assert Solution.num_routes(solution) == 2
      assert Solution.feasible?(solution)
    end

    test "each route visits clients" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [60])
        |> Model.add_client(x: 20, y: 0, delivery: [60])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      # Each route should have delivery load
      route0_delivery = Solution.route_delivery(solution, 0)
      route1_delivery = Solution.route_delivery(solution, 1)

      assert Enum.sum(route0_delivery) > 0
      assert Enum.sum(route1_delivery) > 0
    end
  end

  describe "route with time windows" do
    test "routes respect time windows" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], tw_early: 0, tw_late: 100)
        |> Model.add_client(x: 20, y: 0, delivery: [10], tw_early: 50, tw_late: 150)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], tw_early: 0, tw_late: 200)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.route_feasible?(solution, 0)
    end
  end

  describe "routes accessor" do
    test "solution has routes field" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert is_list(solution.routes)
      assert solution.routes != []
    end

    test "routes contain client indices" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      # Get all clients from all routes
      all_clients =
        solution.routes
        |> List.flatten()
        |> Enum.sort()

      # Should have clients 1 and 2 (0 is depot)
      assert all_clients == [1, 2]
    end
  end

  describe "route depots" do
    test "single depot routes" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      # Route starts and ends at depot 0
      assert Solution.route_feasible?(solution, 0)
    end

    test "multi-depot solution" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 100, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 90, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      assert Solution.feasible?(solution)
    end
  end

  # ==========================================
  # New NIF-based route tests (PyVRP parity)
  # ==========================================

  describe "route excess_load" do
    test "feasible route has zero excess load" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [30])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      excess = Solution.route_excess_load(solution, 0)
      assert is_list(excess)
      assert Enum.all?(excess, &(&1 == 0))
    end

    test "has_excess_load is false for feasible route" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [30])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      refute Solution.route_has_excess_load?(solution, 0)
    end

    test "multi-dimensional excess_load" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [30, 20], pickup: [0, 0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100, 100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      excess = Solution.route_excess_load(solution, 0)
      assert length(excess) == 2
    end
  end

  describe "route time_warp" do
    test "feasible route has zero time_warp" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], tw_early: 0, tw_late: 1000)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], tw_early: 0, tw_late: 2000)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      if Solution.feasible?(solution) do
        assert Solution.route_time_warp(solution, 0) == 0
      end
    end

    test "has_time_warp is false for feasible route" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      refute Solution.route_has_time_warp?(solution, 0)
    end
  end

  describe "route excess_distance" do
    test "route without distance constraint has zero excess" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_excess_distance(solution, 0) == 0
    end

    test "has_excess_distance is false for unconstrained route" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      refute Solution.route_has_excess_distance?(solution, 0)
    end

    test "max_distance constraint" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        # Short max_distance
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], max_distance: 1000)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      # Check excess_distance is accessible
      excess = Solution.route_excess_distance(solution, 0)
      assert is_integer(excess)
    end
  end

  describe "route overtime" do
    test "route without overtime constraint" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      overtime = Solution.route_overtime(solution, 0)
      assert is_integer(overtime)
      assert overtime >= 0
    end
  end

  describe "route vehicle_type" do
    test "single vehicle type" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_vehicle_type(solution, 0) == 0
    end

    test "multiple vehicle types" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      vtype = Solution.route_vehicle_type(solution, 0)
      assert vtype in [0, 1]
    end
  end

  describe "route start_depot and end_depot" do
    test "single depot" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_start_depot(solution, 0) == 0
      assert Solution.route_end_depot(solution, 0) == 0
    end

    test "multiple depots" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 100, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      start_depot = Solution.route_start_depot(solution, 0)
      end_depot = Solution.route_end_depot(solution, 0)

      # Depots are indices 0 or 1
      assert start_depot in [0, 1]
      assert end_depot in [0, 1]
    end
  end

  describe "route num_trips" do
    test "single trip route" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_num_trips(solution, 0) == 1
    end
  end

  describe "route centroid" do
    test "returns tuple of floats" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 10, delivery: [10])
        |> Model.add_client(x: 20, y: 20, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      {cx, cy} = Solution.route_centroid(solution, 0)
      assert is_float(cx)
      assert is_float(cy)
    end

    test "centroid is within bounds" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      {cx, cy} = Solution.route_centroid(solution, 0)
      # Centroid should be somewhere between clients
      assert cx >= 0 and cx <= 20
      assert cy >= 0
    end
  end

  describe "route timing" do
    test "start_time is non-negative" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_start_time(solution, 0) >= 0
    end

    test "end_time >= start_time" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      start_time = Solution.route_start_time(solution, 0)
      end_time = Solution.route_end_time(solution, 0)
      assert end_time >= start_time
    end

    test "slack is non-negative" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_slack(solution, 0) >= 0
    end
  end

  describe "route service and travel duration" do
    test "service_duration matches client service" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], service_duration: 100)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      service = Solution.route_service_duration(solution, 0)
      assert service == 100
    end

    test "travel_duration is positive for non-trivial route" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 100, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      travel = Solution.route_travel_duration(solution, 0)
      assert travel > 0
    end

    test "wait_duration is non-negative" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      wait = Solution.route_wait_duration(solution, 0)
      assert wait >= 0
    end

    test "duration components sum correctly" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], service_duration: 50)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      total = Solution.route_duration(solution, 0)
      travel = Solution.route_travel_duration(solution, 0)
      service = Solution.route_service_duration(solution, 0)
      wait = Solution.route_wait_duration(solution, 0)
      overtime = Solution.route_overtime(solution, 0)

      # Duration includes travel, service, waiting, and overtime
      # Note: slight differences due to time warp handling
      expected = travel + service + wait + overtime
      # Allow small rounding errors
      assert abs(total - expected) <= 1
    end
  end

  describe "route costs" do
    test "distance_cost is non-negative" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_distance_cost(solution, 0) >= 0
    end

    test "duration_cost is non-negative" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_duration_cost(solution, 0) >= 0
    end

    test "unit_distance_cost affects distance_cost" do
      # Higher unit cost should result in higher total distance cost
      model1 =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], unit_distance_cost: 1)

      model2 =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], unit_distance_cost: 10)

      {:ok, result1} = Solver.solve(model1, stop: ExVrp.StoppingCriteria.max_iterations(50))
      {:ok, result2} = Solver.solve(model2, stop: ExVrp.StoppingCriteria.max_iterations(50))

      cost1 = Solution.route_distance_cost(result1.best, 0)
      cost2 = Solution.route_distance_cost(result2.best, 0)

      # Higher unit cost should result in proportionally higher cost
      assert cost2 > cost1
    end
  end

  describe "route prizes" do
    test "prizes is non-negative" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      assert Solution.route_prizes(solution, 0) >= 0
    end

    test "prizes match client prizes" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], prize: 100)
        |> Model.add_client(x: 20, y: 0, delivery: [10], prize: 50)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      # Total prizes should be 150 (100 + 50)
      prizes = Solution.route_prizes(solution, 0)
      assert prizes == 150
    end
  end

  describe "route visits" do
    test "visits returns client indices" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      visits = Solution.route_visits(solution, 0)
      assert is_list(visits)
      assert length(visits) == 2
      # Clients 1 and 2 (0 is depot)
      assert Enum.sort(visits) == [1, 2]
    end

    test "visits for invalid route index returns empty" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(50))
      solution = result.best

      visits = Solution.route_visits(solution, 999)
      assert visits == []
    end
  end

  describe "route constraint combinations" do
    test "capacity and time window constraints" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [40], tw_early: 0, tw_late: 100)
        |> Model.add_client(x: 20, y: 0, delivery: [40], tw_early: 50, tw_late: 200)
        |> Model.add_vehicle_type(num_available: 2, capacity: [50], tw_early: 0, tw_late: 300)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(200))
      solution = result.best

      # Solution should be feasible or not based on constraints
      if Solution.feasible?(solution) do
        # All routes should be feasible
        for idx <- 0..(Solution.num_routes(solution) - 1) do
          assert Solution.route_feasible?(solution, idx)
          refute Solution.route_has_excess_load?(solution, idx)
          refute Solution.route_has_time_warp?(solution, idx)
        end
      end
    end

    test "all constraint checks together" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], max_distance: 1000)

      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(100))
      solution = result.best

      # Check all constraint-related functions work
      route_idx = 0
      _feasible = Solution.route_feasible?(solution, route_idx)
      _excess_load = Solution.route_excess_load(solution, route_idx)
      _has_excess_load = Solution.route_has_excess_load?(solution, route_idx)
      _time_warp = Solution.route_time_warp(solution, route_idx)
      _has_time_warp = Solution.route_has_time_warp?(solution, route_idx)
      _excess_distance = Solution.route_excess_distance(solution, route_idx)
      _has_excess_distance = Solution.route_has_excess_distance?(solution, route_idx)
      _overtime = Solution.route_overtime(solution, route_idx)

      # All should be accessible without error
      assert true
    end
  end
end

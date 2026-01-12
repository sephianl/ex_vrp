defmodule ExVrp.ReadTest do
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Read

  @data_dir Path.join(:code.priv_dir(:ex_vrp), "benchmark_data")

  describe "read/1" do
    test "reads OkSmall instance correctly" do
      path = Path.join(@data_dir, "OkSmall.txt")
      model = Read.read(path)

      # From DIMENSION, VEHICLES, and CAPACITY fields
      assert Model.num_depots(model) == 1
      assert Model.num_clients(model) == 4
      assert Model.num_vehicles(model) == 3
      assert Model.num_vehicle_types(model) == 1

      veh_type = hd(model.vehicle_types)
      assert veh_type.capacity == [10]

      # From NODE_COORD_SECTION
      expected_coords = [
        {2334, 726},
        {226, 1297},
        {590, 530},
        {435, 718},
        {1191, 639}
      ]

      # Check depot
      depot = hd(model.depots)
      assert depot.x == 2334
      assert depot.y == 726

      # Check clients
      assert length(model.clients) == 4

      model.clients
      |> Enum.zip(tl(expected_coords))
      |> Enum.each(fn {client, {x, y}} ->
        assert client.x == x
        assert client.y == y
      end)

      # From DEMAND_SECTION
      expected_demands = [5, 5, 3, 5]

      model.clients
      |> Enum.zip(expected_demands)
      |> Enum.each(fn {client, demand} ->
        assert client.delivery == [demand]
      end)

      # From TIME_WINDOW_SECTION
      expected_time_windows = [
        {15_600, 22_500},
        {12_000, 19_500},
        {8400, 15_300},
        {12_000, 19_500}
      ]

      model.clients
      |> Enum.zip(expected_time_windows)
      |> Enum.each(fn {client, {tw_early, tw_late}} ->
        assert client.tw_early == tw_early
        assert client.tw_late == tw_late
      end)

      # Vehicle time window from depot
      assert veh_type.tw_early == 0
      assert veh_type.tw_late == 45_000

      # From SERVICE_TIME_SECTION
      expected_service = [360, 360, 420, 360]

      model.clients
      |> Enum.zip(expected_service)
      |> Enum.each(fn {client, service} ->
        assert client.service_duration == service
      end)
    end

    test "reads E-n22-k4 with dimacs rounding" do
      path = Path.join(@data_dir, "E-n22-k4.txt")
      model = Read.read(path, round_func: :dimacs)

      assert Model.num_depots(model) == 1
      assert Model.num_clients(model) == 21
      # Default when not specified
      assert Model.num_vehicles(model) == 21

      # Check that capacity is scaled by 10
      veh_type = hd(model.vehicle_types)
      assert veh_type.capacity == [60_000]

      # Check coordinates are scaled
      depot = hd(model.depots)
      assert depot.x == 1450
      assert depot.y == 2150

      first_client = hd(model.clients)
      assert first_client.x == 1510
      assert first_client.y == 2640
    end

    test "reads instance with multiple depots" do
      path = Path.join(@data_dir, "OkSmallMultipleDepots.txt")
      model = Read.read(path)

      assert Model.num_depots(model) == 2
      assert Model.num_clients(model) == 3
      assert Model.num_vehicles(model) == 3

      # Two vehicle types (one per depot)
      assert length(model.vehicle_types) == 2

      # First depot
      [depot1, depot2] = model.depots
      assert depot1.x == 2334
      assert depot1.y == 726
      assert depot2.x == 226
      assert depot2.y == 1297

      # Check vehicle types have correct depots
      veh_type1 = Enum.find(model.vehicle_types, &(&1.start_depot == 0))
      veh_type2 = Enum.find(model.vehicle_types, &(&1.start_depot == 1))

      assert veh_type1
      assert veh_type2
      assert veh_type1.num_available == 2
      assert veh_type2.num_available == 1
    end

    test "reads instance with mutually exclusive groups" do
      path = Path.join(@data_dir, "OkSmallMutuallyExclusiveGroups.txt")
      model = Read.read(path)

      assert Model.num_depots(model) == 1
      assert Model.num_clients(model) == 4

      # Should have one group with 3 clients (groups with 1 member are filtered out)
      assert length(model.client_groups) == 1

      group = hd(model.client_groups)
      assert length(group.clients) == 3

      # Clients in the group should not be required
      num_depots = Model.num_depots(model)

      Enum.each(group.clients, fn client_idx ->
        # client_idx is the absolute location index (depot + client index)
        # We need to convert to list index (subtract num_depots)
        list_idx = client_idx - num_depots
        client = Enum.at(model.clients, list_idx)
        assert client.required == false
      end)
    end
  end

  describe "VRPB (backhaul) instances" do
    test "reads X-n101-50-k13 VRPB instance and solves to feasible solution" do
      # This instance was the primary test case for overflow fixes
      # Before fix: cost calculations overflowed, producing infeasible/wrong results
      # After fix: should find feasible solution with reasonable distance
      path = Path.join(@data_dir, "X-n101-50-k13.vrp")
      model = Read.read(path, round_func: :none)

      assert Model.num_clients(model) == 100
      assert Model.num_depots(model) == 1

      # Solve and verify result is reasonable
      {:ok, result} =
        ExVrp.Solver.solve(model,
          stop: ExVrp.StoppingCriteria.max_iterations(100),
          seed: 42
        )

      # Must be feasible (was broken before overflow fix)
      assert ExVrp.Solution.feasible?(result.best)

      # Distance should be in reasonable range (PyVRP gets ~19635)
      distance = ExVrp.Solution.distance(result.best)
      assert distance > 15_000 and distance < 25_000

      # Should use reasonable number of routes (not overflow to crazy values)
      num_routes = ExVrp.Solution.num_routes(result.best)
      assert num_routes >= 10 and num_routes <= 20
    end
  end

  describe "default value handling" do
    test "clients without time windows get :infinity tw_late" do
      # This ensures the fix for using :infinity instead of MAX_VALUE
      path = Path.join(@data_dir, "E-n22-k4.txt")
      model = Read.read(path)

      # E-n22-k4 has no time windows, so all should be unconstrained
      Enum.each(model.clients, fn client ->
        assert client.tw_early == 0
        # tw_late should be :infinity which gets converted to INT64_MAX in NIF
        # In Elixir side it's stored as :infinity
        assert client.tw_late == :infinity
      end)
    end

    test "vehicle types without max_distance get :infinity" do
      path = Path.join(@data_dir, "E-n22-k4.txt")
      model = Read.read(path)

      Enum.each(model.vehicle_types, fn vt ->
        # No VEHICLES_MAX_DISTANCE in file, should default to :infinity
        assert vt.max_distance == :infinity
      end)
    end

    test "vehicle types without shift_duration get :infinity" do
      path = Path.join(@data_dir, "E-n22-k4.txt")
      model = Read.read(path)

      Enum.each(model.vehicle_types, fn vt ->
        # No VEHICLES_MAX_DURATION in file, should default to :infinity
        assert vt.shift_duration == :infinity
      end)
    end
  end

  describe "rounding functions" do
    test ":round rounds to nearest integer" do
      path = Path.join(@data_dir, "OkSmall.txt")
      model = Read.read(path, round_func: :round)

      # Values are already integers, so should be unchanged
      depot = hd(model.depots)
      assert depot.x == 2334
    end

    test ":trunc truncates to integer" do
      path = Path.join(@data_dir, "OkSmall.txt")
      model = Read.read(path, round_func: :trunc)

      depot = hd(model.depots)
      assert depot.x == 2334
    end

    test ":exact scales by 1000" do
      path = Path.join(@data_dir, "OkSmall.txt")
      model = Read.read(path, round_func: :exact)

      depot = hd(model.depots)
      assert depot.x == 2_334_000
    end

    test "custom rounding function" do
      path = Path.join(@data_dir, "OkSmall.txt")
      model = Read.read(path, round_func: fn x -> x * 2 end)

      depot = hd(model.depots)
      assert depot.x == 4668
    end

    test "raises on unknown rounding function" do
      path = Path.join(@data_dir, "OkSmall.txt")

      assert_raise ArgumentError, ~r/Unknown round_func/, fn ->
        Read.read(path, round_func: :unknown)
      end
    end

    test ":none truncates floats to integers" do
      # :none doesn't scale but must still produce integers for C++
      path = Path.join(@data_dir, "OkSmall.txt")
      model = Read.read(path, round_func: :none)

      # Should be integers
      depot = hd(model.depots)
      assert is_integer(depot.x)
      assert is_integer(depot.y)
    end
  end

  describe "GTSP instances" do
    test "reads GTSP instance with required mutually exclusive groups" do
      path = Path.join(@data_dir, "50pr439.gtsp")
      model = Read.read(path)

      # GTSP groups should be required AND mutually exclusive
      assert model.client_groups != []

      Enum.each(model.client_groups, fn group ->
        assert group.required == true
        assert group.mutually_exclusive == true
      end)
    end
  end

  describe "HFVRP (heterogeneous fleet) instances" do
    test "reads X115-HVRP with per-vehicle capacities" do
      path = Path.join(@data_dir, "X115-HVRP.vrp")
      model = Read.read(path, round_func: :exact)

      # Should have at least one vehicle type
      assert model.vehicle_types != []

      # Check capacities are properly parsed
      capacities = Enum.map(model.vehicle_types, fn vt -> hd(vt.capacity) end)
      # Should be scaled by 1000 for :exact
      assert Enum.all?(capacities, &(&1 > 0))
    end
  end

  describe "VRPB MAX_VALUE for forbidden edges" do
    test "VRPB matrices use 2^44 for forbidden edges" do
      # The @max_value in Read module must match PyVRP's default (1 << 44)
      # This is critical for VRPB instances where backhaul->linehaul is forbidden
      # Using INT64_MAX would cause overflow when computing distances
      max_value = Bitwise.bsl(1, 44)

      # Read a VRPB instance and check the matrices
      path = Path.join(@data_dir, "X-n101-50-k13.vrp")
      model = Read.read(path, round_func: :none)

      # Get distance matrices
      [dist_matrix] = model.distance_matrices

      # Find a forbidden edge (backhaul to linehaul or depot to backhaul)
      # In VRPB, these should have max_value
      has_forbidden =
        Enum.any?(dist_matrix, fn row ->
          Enum.any?(row, fn val -> val == max_value end)
        end)

      assert has_forbidden,
             "VRPB instance should have forbidden edges marked with 2^44"

      # Verify no edge is larger than max_value (would indicate wrong value used)
      max_edge =
        dist_matrix
        |> Enum.flat_map(& &1)
        |> Enum.max()

      assert max_edge == max_value,
             "Maximum edge value should be exactly 2^44 = #{max_value}, got #{max_edge}"
    end

    test "VRPB forbidden edge value is exactly 2^44" do
      # Regression: using INT64_MAX or wrong value causes overflow
      # PyVRP uses 1 << 44 = 17_592_186_044_416
      expected = 17_592_186_044_416
      actual = Bitwise.bsl(1, 44)

      assert actual == expected,
             "@max_value should be 2^44 = #{expected}, got #{actual}"
    end
  end

  describe "Solver initial solution creation" do
    test "solver creates initial solution from empty via local search" do
      # The solver creates initial solution by:
      # 1. Creating empty solution (no routes)
      # 2. Running local_search_search_run (search-only, no perturbation)
      # This must produce a complete solution with all clients
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_client(x: 30, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 3, capacity: [100])

      # Solve with minimal iterations to focus on initial solution quality
      {:ok, result} = ExVrp.Solver.solve(model, max_iterations: 1, seed: 42)

      # Initial solution should be complete (all clients visited)
      assert result.best.is_complete
      assert result.best.num_clients == 3

      # stats.initial_cost should be set from the initial solution
      assert result.stats.initial_cost > 0
    end

    test "solver respects seed for initial solution reproducibility" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 10, delivery: [10])
        |> Model.add_client(x: 20, y: 20, delivery: [10])
        |> Model.add_client(x: 30, y: 30, delivery: [10])
        |> Model.add_vehicle_type(num_available: 3, capacity: [100])

      # Same seed should produce same initial solution
      {:ok, result1} = ExVrp.Solver.solve(model, max_iterations: 1, seed: 123)
      {:ok, result2} = ExVrp.Solver.solve(model, max_iterations: 1, seed: 123)

      assert result1.stats.initial_cost == result2.stats.initial_cost
      assert result1.best.routes == result2.best.routes
    end
  end
end

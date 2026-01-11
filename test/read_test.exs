defmodule ExVrp.ReadTest do
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Read

  @data_dir Path.join(__DIR__, "data")

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
  end
end

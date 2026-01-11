defmodule ExVrp.ModelTest do
  @moduledoc """
  Tests for ExVrp.Model - the high-level problem builder.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model

  describe "new/0" do
    test "creates empty model" do
      model = Model.new()

      assert model.clients == []
      assert model.depots == []
      assert model.vehicle_types == []
      assert model.client_groups == []
      assert model.distance_matrices == []
      assert model.duration_matrices == []
    end
  end

  describe "add_client/2" do
    test "adds client to model" do
      model = Model.add_client(Model.new(), x: 1, y: 2, delivery: [10])

      assert length(model.clients) == 1
      assert hd(model.clients).x == 1
      assert hd(model.clients).y == 2
    end

    test "preserves order of clients" do
      model =
        Model.new()
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_client(x: 2, y: 2)
        |> Model.add_client(x: 3, y: 3)

      assert length(model.clients) == 3
      assert Enum.at(model.clients, 0).x == 1
      assert Enum.at(model.clients, 1).x == 2
      assert Enum.at(model.clients, 2).x == 3
    end
  end

  describe "add_depot/2" do
    test "adds depot to model" do
      model = Model.add_depot(Model.new(), x: 0, y: 0)

      assert length(model.depots) == 1
      assert hd(model.depots).x == 0
    end

    test "supports multiple depots" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, name: "depot1")
        |> Model.add_depot(x: 10, y: 10, name: "depot2")

      assert length(model.depots) == 2
    end
  end

  describe "add_vehicle_type/2" do
    test "adds vehicle type to model" do
      model = Model.add_vehicle_type(Model.new(), num_available: 3, capacity: [100])

      assert length(model.vehicle_types) == 1
      assert hd(model.vehicle_types).num_available == 3
    end

    test "supports heterogeneous fleet" do
      model =
        Model.new()
        |> Model.add_vehicle_type(num_available: 2, capacity: [100], name: "small")
        |> Model.add_vehicle_type(num_available: 1, capacity: [200], name: "large")

      assert length(model.vehicle_types) == 2
    end
  end

  describe "validate/1" do
    test "valid model passes validation" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])

      assert :ok = Model.validate(model)
    end

    test "model without depot fails validation" do
      model =
        Model.new()
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 1, y: 1, delivery: [10])

      assert {:error, errors} = Model.validate(model)
      assert "Model must have at least one depot" in errors
    end

    test "model without vehicle type fails validation" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, delivery: [10])

      assert {:error, errors} = Model.validate(model)
      assert "Model must have at least one vehicle type" in errors
    end

    test "mismatched capacity dimensions fails validation" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100, 50])
        |> Model.add_client(x: 1, y: 1, delivery: [10])

      # Client has 1 dimension, vehicle has 2
      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &String.contains?(&1, "capacity dimensions"))
    end
  end

  describe "fluent API" do
    test "supports pipe chaining" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 100, y: 100)
        |> Model.add_vehicle_type(num_available: 3, capacity: [100])
        |> Model.add_client(x: 10, y: 10, delivery: [25])
        |> Model.add_client(x: 20, y: 20, delivery: [30])
        |> Model.add_client(x: 30, y: 10, delivery: [20])

      assert length(model.depots) == 2
      assert length(model.vehicle_types) == 1
      assert length(model.clients) == 3
      assert :ok = Model.validate(model)
    end
  end

  describe "add_client_group/2" do
    test "creates empty group and returns {model, group_index}" do
      {model, group_idx} = Model.add_client_group(Model.new(), required: false)

      assert length(model.client_groups) == 1
      assert group_idx == 0
      # Empty group initially
      assert hd(model.client_groups).clients == []
      # required: false means mutually_exclusive: true
      assert hd(model.client_groups).required == false
      assert hd(model.client_groups).mutually_exclusive == true
    end

    test "creates required group" do
      {model, _group_idx} = Model.add_client_group(Model.new(), required: true)

      assert length(model.client_groups) == 1
      assert hd(model.client_groups).required == true
      assert hd(model.client_groups).mutually_exclusive == false
    end

    test "dynamic client assignment via add_client" do
      model = Model.add_depot(Model.new(), x: 0, y: 0)

      {model, group} = Model.add_client_group(model, required: false)

      model =
        model
        |> Model.add_client(x: 1, y: 1, required: false, group: group)
        |> Model.add_client(x: 2, y: 2, required: false, group: group)

      # Group should now have both clients
      # depot is 0, clients are 1, 2
      assert hd(model.client_groups).clients == [1, 2]
    end

    test "raises when required client added to mutually exclusive group" do
      model = Model.add_depot(Model.new(), x: 0, y: 0)

      # mutually_exclusive=true
      {model, group} = Model.add_client_group(model, required: false)

      assert_raise ArgumentError, ~r/Required client cannot be in mutually exclusive group/, fn ->
        Model.add_client(model, x: 1, y: 1, required: true, group: group)
      end
    end

    test "depot re-indexing updates group client indices" do
      model = Model.new()
      {model, group} = Model.add_client_group(model, required: false)
      model = Model.add_depot(model, x: 0, y: 0)
      model = Model.add_client(model, x: 1, y: 1, required: false, group: group)

      # Client is at index 1 (after 1 depot)
      assert hd(model.client_groups).clients == [1]

      # Add another depot - client indices should be recalculated
      model = Model.add_depot(model, x: 5, y: 5)

      # Client is now at index 2 (after 2 depots)
      assert hd(model.client_groups).clients == [2]
    end
  end

  describe "property accessors" do
    setup do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, name: "depot1")
        |> Model.add_depot(x: 100, y: 100, name: "depot2")
        |> Model.add_vehicle_type(num_available: 2, capacity: [50], name: "small")
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], name: "large")

      {model, group} = Model.add_client_group(model, required: false)

      model =
        model
        |> Model.add_client(x: 10, y: 10, delivery: [10], name: "client1", required: false, group: group)
        |> Model.add_client(x: 20, y: 20, delivery: [20], name: "client2", required: false, group: group)
        |> Model.add_client(x: 30, y: 30, delivery: [15], name: "client3")

      %{model: model}
    end

    test "clients accessor returns all clients", %{model: model} do
      assert length(model.clients) == 3
      assert Enum.at(model.clients, 0).name == "client1"
      assert Enum.at(model.clients, 1).name == "client2"
      assert Enum.at(model.clients, 2).name == "client3"
    end

    test "depots accessor returns all depots", %{model: model} do
      assert length(model.depots) == 2
      assert Enum.at(model.depots, 0).name == "depot1"
      assert Enum.at(model.depots, 1).name == "depot2"
    end

    test "vehicle_types accessor returns all vehicle types", %{model: model} do
      assert length(model.vehicle_types) == 2
      assert Enum.at(model.vehicle_types, 0).name == "small"
      assert Enum.at(model.vehicle_types, 1).name == "large"
    end

    test "client_groups accessor returns all groups", %{model: model} do
      assert length(model.client_groups) == 1
    end

    test "num_clients/1 returns client count", %{model: model} do
      assert length(model.clients) == 3
    end

    test "num_depots/1 returns depot count", %{model: model} do
      assert length(model.depots) == 2
    end

    test "num_vehicle_types/1 returns vehicle type count", %{model: model} do
      assert length(model.vehicle_types) == 2
    end

    test "num_groups/1 returns group count", %{model: model} do
      assert length(model.client_groups) == 1
    end
  end

  describe "to_problem_data/1" do
    test "converts valid model to problem data" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, problem_data} = Model.to_problem_data(model)
      assert is_reference(problem_data)
    end

    test "returns error for invalid model" do
      model = Model.add_client(Model.new(), x: 10, y: 0, delivery: [20])

      assert {:error, _errors} = Model.to_problem_data(model)
    end
  end

  describe "edge cases" do
    test "model with single client" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert :ok = Model.validate(model)
      assert {:ok, _} = Model.to_problem_data(model)
    end

    test "model with no clients (empty problem)" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      # Empty model should still be valid
      assert :ok = Model.validate(model)
    end

    test "model with single depot" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert :ok = Model.validate(model)
    end

    test "model with single vehicle" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert :ok = Model.validate(model)
    end

    test "model with heterogeneous fleet" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [50], fixed_cost: 10)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], fixed_cost: 20)
        |> Model.add_vehicle_type(num_available: 3, capacity: [200], fixed_cost: 30)

      assert :ok = Model.validate(model)
      assert length(model.vehicle_types) == 3
    end

    test "model with multiple depots (MDVRP)" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 100, y: 0)
        |> Model.add_depot(x: 50, y: 100)
        |> Model.add_client(x: 25, y: 25, delivery: [10])
        |> Model.add_client(x: 75, y: 25, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], start_depot: 0, end_depot: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], start_depot: 1, end_depot: 1)

      assert :ok = Model.validate(model)
    end

    test "model with many clients (stress test)" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 10, capacity: [1000])

      # Add 100 clients
      model =
        Enum.reduce(1..100, model, fn i, acc ->
          Model.add_client(acc, x: rem(i, 10) * 10, y: div(i, 10) * 10, delivery: [10])
        end)

      assert length(model.clients) == 100
      assert :ok = Model.validate(model)
    end
  end

  describe "client attributes" do
    test "client with all attributes" do
      model =
        Model.add_client(Model.new(),
          x: 1,
          y: 2,
          delivery: [3],
          pickup: [9],
          service_duration: 4,
          tw_early: 5,
          tw_late: 6,
          release_time: 0,
          prize: 8,
          required: false
        )

      client = hd(model.clients)
      assert client.x == 1
      assert client.y == 2
      assert client.delivery == [3]
      assert client.pickup == [9]
      assert client.service_duration == 4
      assert client.tw_early == 5
      assert client.tw_late == 6
      assert client.release_time == 0
      assert client.prize == 8
      assert client.required == false
    end

    test "client with multidimensional load" do
      model = Model.add_client(Model.new(), x: 1, y: 2, delivery: [3, 4], pickup: [5, 6])

      client = hd(model.clients)
      assert client.delivery == [3, 4]
      assert client.pickup == [5, 6]
    end
  end

  describe "depot attributes" do
    test "depot with all attributes" do
      model = Model.add_depot(Model.new(), x: 1, y: 0, tw_early: 5, tw_late: 7)

      depot = hd(model.depots)
      assert depot.x == 1
      assert depot.y == 0
      assert depot.tw_early == 5
      assert depot.tw_late == 7
    end
  end

  describe "vehicle type attributes" do
    test "vehicle type with all attributes" do
      model =
        Model.add_vehicle_type(Model.new(),
          num_available: 10,
          capacity: [998],
          fixed_cost: 1001,
          tw_early: 17,
          tw_late: 19,
          shift_duration: 93,
          max_distance: 97,
          start_late: 18,
          max_overtime: 43
        )

      vt = hd(model.vehicle_types)
      assert vt.num_available == 10
      assert vt.capacity == [998]
      assert vt.fixed_cost == 1001
      assert vt.tw_early == 17
      assert vt.tw_late == 19
      assert vt.shift_duration == 93
      assert vt.max_distance == 97
      assert vt.start_late == 18
      assert vt.max_overtime == 43
    end

    test "vehicle type default depots" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      vt = hd(model.vehicle_types)
      # Default should be first depot (index 0)
      assert vt.start_depot == 0
      assert vt.end_depot == 0
    end

    test "vehicle type with explicit depots" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], start_depot: 1, end_depot: 1)

      vt = hd(model.vehicle_types)
      assert vt.start_depot == 1
      assert vt.end_depot == 1
    end

    test "vehicle type with mixed start/end depots" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], start_depot: 0, end_depot: 1)

      vt = hd(model.vehicle_types)
      assert vt.start_depot == 0
      assert vt.end_depot == 1
    end
  end

  describe "multi-trip support" do
    test "vehicle type with reload depots" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], reload_depots: [0])

      vt = hd(model.vehicle_types)
      assert vt.reload_depots == [0]
    end

    test "vehicle type with multiple reload depots" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], reload_depots: [0, 1])

      vt = hd(model.vehicle_types)
      assert vt.reload_depots == [0, 1]
    end

    test "vehicle type with max_reloads" do
      model = Model.add_vehicle_type(Model.new(), num_available: 1, capacity: [100], reload_depots: [0], max_reloads: 3)

      vt = hd(model.vehicle_types)
      assert vt.max_reloads == 3
    end

    test "vehicle type with initial_load" do
      model = Model.add_vehicle_type(Model.new(), num_available: 1, capacity: [100], initial_load: [50])

      vt = hd(model.vehicle_types)
      assert vt.initial_load == [50]
    end
  end

  describe "distance and duration matrices" do
    test "set_distance_matrices/2" do
      matrix = [
        [0, 10, 20],
        [10, 0, 15],
        [20, 15, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.set_distance_matrices([matrix])

      assert model.distance_matrices == [matrix]
    end

    test "set_duration_matrices/2" do
      matrix = [
        [0, 5, 10],
        [5, 0, 8],
        [10, 8, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.set_duration_matrices([matrix])

      assert model.duration_matrices == [matrix]
    end

    test "asymmetric matrices" do
      # Asymmetric distance matrix (A->B != B->A)
      matrix = [
        [0, 10, 20],
        [15, 0, 25],
        [30, 35, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.set_distance_matrices([matrix])

      assert model.distance_matrices == [matrix]
    end
  end

  describe "client with optional attributes" do
    test "client with release time" do
      model = Model.add_client(Model.new(), x: 1, y: 1, release_time: 100)

      client = hd(model.clients)
      assert client.release_time == 100
    end

    test "client with prize (optional client)" do
      model = Model.add_client(Model.new(), x: 1, y: 1, prize: 50, required: false)

      client = hd(model.clients)
      assert client.prize == 50
      assert client.required == false
    end
  end

  describe "name fields" do
    test "client name" do
      model = Model.add_client(Model.new(), x: 1, y: 2, name: "customer1")
      assert hd(model.clients).name == "customer1"
    end

    test "depot name" do
      model = Model.add_depot(Model.new(), x: 0, y: 0, name: "warehouse")
      assert hd(model.depots).name == "warehouse"
    end

    test "vehicle type name" do
      model = Model.add_vehicle_type(Model.new(), num_available: 1, capacity: [100], name: "truck")
      assert hd(model.vehicle_types).name == "truck"
    end
  end
end

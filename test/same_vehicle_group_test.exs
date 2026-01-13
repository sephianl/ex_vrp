defmodule ExVrp.SameVehicleGroupTest do
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.SameVehicleGroup
  alias ExVrp.Solution

  describe "SameVehicleGroup struct" do
    test "constructor initializes fields" do
      group = SameVehicleGroup.new(clients: [1, 2, 3], name: "test")

      assert group.clients == [1, 2, 3]
      assert group.name == "test"
    end

    test "empty constructor creates empty group" do
      group = SameVehicleGroup.new()

      assert group.clients == []
      assert group.name == ""
    end

    test "add_client adds clients" do
      group =
        SameVehicleGroup.new()
        |> SameVehicleGroup.add_client(1)
        |> SameVehicleGroup.add_client(2)

      assert group.clients == [1, 2]
    end

    test "add_client raises for duplicate" do
      group = SameVehicleGroup.new(clients: [1, 2])

      assert_raise ArgumentError, ~r/already in same-vehicle group/, fn ->
        SameVehicleGroup.add_client(group, 1)
      end
    end

    test "clear empties the group" do
      group = SameVehicleGroup.new(clients: [1, 2, 3])
      assert SameVehicleGroup.size(group) == 3

      cleared = SameVehicleGroup.clear(group)
      assert SameVehicleGroup.size(cleared) == 0
      assert cleared.clients == []
    end

    test "size returns correct count" do
      assert SameVehicleGroup.size(SameVehicleGroup.new()) == 0
      assert SameVehicleGroup.size(SameVehicleGroup.new(clients: [1, 2, 3])) == 3
    end

    test "empty? returns correct value" do
      assert SameVehicleGroup.empty?(SameVehicleGroup.new()) == true
      assert SameVehicleGroup.empty?(SameVehicleGroup.new(clients: [1])) == false
    end
  end

  describe "Model.add_same_vehicle_group/3" do
    test "adds same-vehicle group to model" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_client(x: 2, y: 2)
        |> Model.add_client(x: 3, y: 3)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      [c1, c2, _c3] = model.clients

      model = Model.add_same_vehicle_group(model, [c1, c2], name: "group1")

      assert length(model.same_vehicle_groups) == 1
      [group] = model.same_vehicle_groups
      assert group.name == "group1"
      # Clients are offset by num_depots (1)
      assert group.clients == [1, 2]
    end

    test "raises when client not in model" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      # Create a client not in the model
      fake_client = ExVrp.Client.new(x: 99, y: 99)

      assert_raise ArgumentError, ~r/Client not in model/, fn ->
        Model.add_same_vehicle_group(model, [fake_client])
      end
    end
  end

  describe "depot addition updates same-vehicle group indices" do
    test "adding depot shifts client indices in same-vehicle groups" do
      # Create model with depot and clients first
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_client(x: 2, y: 2)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      [c1, c2] = model.clients

      # Add same-vehicle group (clients will have indices 1 and 2)
      model = Model.add_same_vehicle_group(model, [c1, c2])
      [group_before] = model.same_vehicle_groups
      assert group_before.clients == [1, 2]

      # Add another depot - indices should shift by 1
      model = Model.add_depot(model, x: 5, y: 5)
      [group_after] = model.same_vehicle_groups
      assert group_after.clients == [2, 3]
    end
  end

  describe "validation" do
    test "validates empty same-vehicle groups" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      # Manually add empty group
      model = %{model | same_vehicle_groups: [SameVehicleGroup.new()]}

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &String.contains?(&1, "empty"))
    end

    test "validates invalid client indices in same-vehicle groups" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      # Manually add group with invalid client index
      bad_group = SameVehicleGroup.new(clients: [999])
      model = %{model | same_vehicle_groups: [bad_group]}

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &String.contains?(&1, "invalid client index"))
    end

    test "validates duplicate clients in same-vehicle groups" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      # Manually add group with duplicate client
      bad_group = SameVehicleGroup.new(clients: [1, 1])
      model = %{model | same_vehicle_groups: [bad_group]}

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &String.contains?(&1, "duplicate"))
    end
  end

  describe "solution feasibility with same-vehicle constraint" do
    test "feasible when same-group clients are on same route" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_client(x: 2, y: 2)
        |> Model.add_client(x: 3, y: 3)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      [c1, c2, _c3] = model.clients

      # Clients c1 and c2 must be on same vehicle
      model = Model.add_same_vehicle_group(model, [c1, c2])

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 100)

      # Check that solution is feasible
      # Note: The solver should respect the same-vehicle constraint
      assert Solution.feasible?(result.best)
    end

    test "partial visits are allowed" do
      # When only some clients from a same-vehicle group are visited,
      # those visited must be on the same route. Unvisited clients are OK.
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1, required: false)
        |> Model.add_client(x: 2, y: 2, required: false)
        |> Model.add_client(x: 3, y: 3, required: false)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      [c1, c2, c3] = model.clients

      # All three must be on same vehicle IF visited
      model = Model.add_same_vehicle_group(model, [c1, c2, c3])

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 100)

      # Solution should be feasible
      assert Solution.feasible?(result.best)
    end

    test "group_feasible? returns true when constraint is satisfied" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 1, y: 1)
        |> Model.add_client(x: 2, y: 2)
        |> Model.add_client(x: 3, y: 3)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      [c1, c2, _c3] = model.clients
      model = Model.add_same_vehicle_group(model, [c1, c2])

      {:ok, result} = ExVrp.solve(model, seed: 42, max_iterations: 100)

      assert Solution.group_feasible?(result.best)
    end
  end
end

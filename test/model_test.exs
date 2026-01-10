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
end

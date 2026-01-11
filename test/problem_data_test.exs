defmodule ExVrp.ProblemDataTest do
  @moduledoc """
  Tests for ProblemData creation and validation.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  describe "create_problem_data/1" do
    test "creates problem data from valid model" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, problem_data} = Model.to_problem_data(model)
      assert is_reference(problem_data)
    end

    test "returns correct number of load dimensions" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20, 10], pickup: [0, 0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100, 50])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_load_dims(problem_data) == 2
    end

    test "single dimension model" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_load_dims(problem_data) == 1
    end

    test "multiple depots" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 100, y: 100)
        |> Model.add_client(x: 50, y: 50, delivery: [20])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "multiple vehicle types" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20])
        |> Model.add_vehicle_type(num_available: 2, capacity: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "with time windows" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20], tw_early: 0, tw_late: 100)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], tw_early: 0, tw_late: 200)

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "with service durations" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20], service_duration: 10)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "with vehicle costs" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          fixed_cost: 100,
          unit_distance_cost: 2,
          unit_duration_cost: 1
        )

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "with multi-trip fields" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [60])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0],
          max_reloads: 2,
          initial_load: [0]
        )

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "with overtime settings" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          shift_duration: 480,
          max_overtime: 60,
          unit_overtime_cost: 5
        )

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "with pickup and delivery" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [20], pickup: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "three load dimensions" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10, 20, 30], pickup: [0, 0, 0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100, 200, 300])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_load_dims(problem_data) == 3
    end
  end

  describe "problem data counts" do
    test "num_clients returns correct count" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_client(x: 30, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_clients(problem_data) == 3
    end

    test "num_depots returns correct count" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 100, y: 0)
        |> Model.add_client(x: 50, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_depots(problem_data) == 2
    end

    test "num_locations returns depots plus clients" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 100, y: 0)
        |> Model.add_client(x: 25, y: 0, delivery: [10])
        |> Model.add_client(x: 50, y: 0, delivery: [10])
        |> Model.add_client(x: 75, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      # 2 depots + 3 clients = 5 locations
      assert Native.problem_data_num_locations(problem_data) == 5
    end

    test "num_vehicle_types returns correct count" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [50])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_vehicle_type(num_available: 3, capacity: [200])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_vehicle_types(problem_data) == 3
    end

    test "num_vehicles returns total fleet size" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 2, capacity: [50])
        |> Model.add_vehicle_type(num_available: 3, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      # 2 + 3 = 5 vehicles
      assert Native.problem_data_num_vehicles(problem_data) == 5
    end
  end

  describe "has_time_windows (PyVRP parity)" do
    test "VRPTW has time windows" do
      # Based on test_has_time_windows with VRPTW instance
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], tw_early: 100, tw_late: 200)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_has_time_windows_nif(problem_data) == true
    end

    test "CVRP does not have time windows" do
      # Based on test_has_time_windows with CVRP instance (no TW)
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_has_time_windows_nif(problem_data) == false
    end

    test "multiple clients with/without TW - has TW if any client has" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        # no TW
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        # has TW
        |> Model.add_client(x: 20, y: 0, delivery: [10], tw_early: 100, tw_late: 200)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_has_time_windows_nif(problem_data) == true
    end
  end

  describe "centroid (PyVRP parity)" do
    test "centroid is average of client coordinates" do
      # Based on test_centroid
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 20, delivery: [10])
        |> Model.add_client(x: 30, y: 40, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {x, y} = Native.problem_data_centroid_nif(problem_data)

      # Centroid of clients (10, 20) and (30, 40)
      assert_in_delta x, 20.0, 0.001
      assert_in_delta y, 30.0, 0.001
    end

    test "centroid excludes depots" do
      model =
        Model.new()
        # far away depot
        |> Model.add_depot(x: 1000, y: 1000)
        |> Model.add_client(x: 0, y: 0, delivery: [10])
        |> Model.add_client(x: 10, y: 10, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {x, y} = Native.problem_data_centroid_nif(problem_data)

      # Centroid should be center of clients only
      assert_in_delta x, 5.0, 0.001
      assert_in_delta y, 5.0, 0.001
    end

    test "single client centroid is client coordinates" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 42, y: 84, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      {x, y} = Native.problem_data_centroid_nif(problem_data)

      assert_in_delta x, 42.0, 0.001
      assert_in_delta y, 84.0, 0.001
    end
  end

  describe "num_profiles (PyVRP parity)" do
    test "single profile by default" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_profiles_nif(problem_data) == 1
    end
  end

  describe "Vehicle type attributes (PyVRP parity)" do
    test "vehicle type with all attributes set" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(
          num_available: 7,
          capacity: [13],
          fixed_cost: 100,
          tw_early: 0,
          tw_late: 1000,
          shift_duration: 500,
          max_distance: 10_000,
          unit_distance_cost: 2,
          unit_duration_cost: 3,
          max_overtime: 100,
          unit_overtime_cost: 5
        )

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "multiple capacities" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10, 20], pickup: [5, 10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100, 200])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_load_dims(problem_data) == 2
    end

    test "with reload depots" do
      # Based on test_validate_raises_for_invalid_reload_depot (valid case)
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_depot(x: 100, y: 0)
        |> Model.add_client(x: 50, y: 0, delivery: [10])
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          reload_depots: [0, 1],
          max_reloads: 2
        )

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end
  end

  describe "Client attributes (PyVRP parity)" do
    test "client with all attributes" do
      # Based on test_client_constructor_initialises_data_fields_correctly
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(
          x: 10,
          y: 20,
          delivery: [5],
          pickup: [3],
          service_duration: 60,
          tw_early: 100,
          tw_late: 200,
          release_time: 50,
          prize: 10
        )
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "float coordinates" do
      model =
        Model.new()
        |> Model.add_depot(x: 0.5, y: 8.2)
        |> Model.add_client(x: 1.25, y: 3.75, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "negative coordinates" do
      model =
        Model.new()
        |> Model.add_depot(x: -10, y: -20)
        |> Model.add_client(x: -5, y: -15, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "zero demand client" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [0])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end
  end

  describe "Depot attributes (PyVRP parity)" do
    test "depot with time windows" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 100, tw_late: 1000)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end

    test "depot with float coordinates" do
      model =
        Model.new()
        |> Model.add_depot(x: 1.25, y: 0.5)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:ok, _problem_data} = Model.to_problem_data(model)
    end
  end

  describe "Matrix access (PyVRP parity)" do
    test "explicit distance and duration matrices" do
      distances = [[0, 100, 200], [100, 0, 150], [200, 150, 0]]
      durations = [[0, 50, 100], [50, 0, 75], [100, 75, 0]]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([durations])

      assert {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_locations(problem_data) == 3
    end
  end

  describe "Validation errors - implemented (PyVRP parity)" do
    test "raises when no depot is provided" do
      # Based on test_problem_data_raises_when_no_depot_is_provided
      model =
        Model.new()
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises when no vehicle type is provided" do
      # Based on test_problem_data_raises_when_no_vehicle_type_is_provided
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises when client load dimensions differ" do
      # Based on test_problem_data_raises_when_pickup_and_delivery_dimensions_differ
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10, 20])
        # different dimensions
        |> Model.add_client(x: 20, y: 0, delivery: [10, 20, 30])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100, 100, 100])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises when vehicle capacity dimensions differ from client" do
      # Based on test_problem_data_raises_when_pickup_delivery_capacity_dimensions_differ
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10, 20])
        # 3 dims vs 2
        |> Model.add_vehicle_type(num_available: 1, capacity: [100, 100, 100])

      assert {:error, _reason} = Model.to_problem_data(model)
    end
  end

  describe "Validation errors (PyVRP parity)" do
    # These tests verify validations that match PyVRP behavior.

    test "raises when matrix dimensions mismatch" do
      # 2x2 but we have 3 locations
      distances = [[0, 100], [100, 0]]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_client(x: 20, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([distances])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises when matrix diagonal is nonzero" do
      # nonzero diagonal
      distances = [[1, 100], [100, 0]]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([[0, 100], [100, 0]])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises for invalid client time windows (late < early)" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], tw_early: 100, tw_late: 50)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises for negative client service duration" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], service_duration: -1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises for negative delivery amount" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [-10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises for release time > tw_late" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10], tw_early: 0, tw_late: 100, release_time: 200)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises for invalid depot time windows" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 100, tw_late: 50)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises for zero num_available vehicles" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 0, capacity: [100])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises for negative vehicle capacity" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [-100])

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises for invalid vehicle depot index" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], start_depot: 1)

      assert {:error, _reason} = Model.to_problem_data(model)
    end

    test "raises for invalid reload depot index" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100], reload_depots: [1])

      assert {:error, _reason} = Model.to_problem_data(model)
    end
  end

  describe "Edge cases (PyVRP parity)" do
    test "large fleet size" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 10, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 100, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_vehicles(problem_data) == 100
    end

    test "many clients" do
      model = Model.add_depot(Model.new(), x: 0, y: 0)

      model =
        Enum.reduce(1..20, model, fn i, acc ->
          Model.add_client(acc, x: i * 10, y: 0, delivery: [10])
        end)

      model = Model.add_vehicle_type(model, num_available: 5, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_clients(problem_data) == 20
    end

    test "many depots" do
      model = Model.new()

      model =
        Enum.reduce(0..4, model, fn i, acc ->
          Model.add_depot(acc, x: i * 100, y: 0)
        end)

      model =
        model
        |> Model.add_client(x: 50, y: 0, delivery: [10])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])

      {:ok, problem_data} = Model.to_problem_data(model)
      assert Native.problem_data_num_depots(problem_data) == 5
    end
  end
end

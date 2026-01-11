defmodule ExVrp.MinimiseFleetTest do
  use ExUnit.Case, async: true

  alias ExVrp.MinimiseFleet
  alias ExVrp.Model
  alias ExVrp.StoppingCriteria

  describe "validation" do
    test "raises error for multiple vehicle types" do
      # Create instance with multiple vehicle types (multi-depot with different vehicle types)
      distances = build_ok_small_distances()

      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        |> Model.add_depot(x: 1000, y: 1000, tw_early: 0, tw_late: 45_000)
        |> Model.add_client(x: 226, y: 1297, delivery: [5])
        |> Model.add_client(x: 590, y: 530, delivery: [5])
        |> Model.add_client(x: 435, y: 718, delivery: [3])
        |> Model.add_client(x: 1191, y: 639, delivery: [5])
        # Two vehicle types
        |> Model.add_vehicle_type(num_available: 2, capacity: [10], start_depot: 0, end_depot: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [15], start_depot: 1, end_depot: 1)
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([distances])

      stop = StoppingCriteria.max_iterations(1)
      assert {:error, msg} = MinimiseFleet.minimise(model, stop)
      assert msg =~ "multiple vehicle types"
    end

    test "minimise! raises ArgumentError for multiple vehicle types" do
      distances = build_ok_small_distances()

      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        |> Model.add_depot(x: 1000, y: 1000, tw_early: 0, tw_late: 45_000)
        |> Model.add_client(x: 226, y: 1297, delivery: [5])
        |> Model.add_client(x: 590, y: 530, delivery: [5])
        |> Model.add_client(x: 435, y: 718, delivery: [3])
        |> Model.add_client(x: 1191, y: 639, delivery: [5])
        |> Model.add_vehicle_type(num_available: 2, capacity: [10], start_depot: 0, end_depot: 0)
        |> Model.add_vehicle_type(num_available: 2, capacity: [15], start_depot: 1, end_depot: 1)
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([distances])

      stop = StoppingCriteria.max_iterations(1)

      assert_raise ArgumentError, ~r/multiple vehicle types/, fn ->
        MinimiseFleet.minimise!(model, stop)
      end
    end

    test "raises error for optional clients (prize-collecting)" do
      # Create instance with optional clients
      distances = build_ok_small_distances()

      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        |> Model.add_client(x: 226, y: 1297, delivery: [5], required: true)
        |> Model.add_client(x: 590, y: 530, delivery: [5], required: false, prize: 100)
        |> Model.add_client(x: 435, y: 718, delivery: [3], required: true)
        |> Model.add_client(x: 1191, y: 639, delivery: [5], required: false, prize: 50)
        |> Model.add_vehicle_type(num_available: 3, capacity: [10], tw_early: 0, tw_late: 45_000)
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([distances])

      stop = StoppingCriteria.max_iterations(1)
      assert {:error, msg} = MinimiseFleet.minimise(model, stop)
      assert msg =~ "optional clients"
    end
  end

  describe "fleet minimisation" do
    test "OkSmall reduces fleet from 3 to 2 vehicles" do
      # The OkSmall instance can be solved with 2 vehicles, not 3
      # Total demand = 5 + 5 + 3 + 5 = 18, capacity = 10
      # Lower bound = ceil(18/10) = 2
      model = build_ok_small_model()

      # Verify starting with 3 vehicles
      [vehicle_type] = model.vehicle_types
      assert vehicle_type.num_available == 3

      stop = StoppingCriteria.max_iterations(10)
      assert {:ok, minimised_type} = MinimiseFleet.minimise(model, stop)

      # Should reduce to 2 vehicles
      assert minimised_type.num_available == 2
    end

    test "OkSmall with multidimensional load respects all dimensions" do
      # With two load dimensions where second dimension sums to 5 with capacity 2
      # Need at least ceil(5/2) = 3 vehicles in dimension 2
      distances = build_ok_small_distances()

      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        # delivery: [dim1, dim2]
        |> Model.add_client(x: 226, y: 1297, delivery: [5, 1], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
        |> Model.add_client(x: 590, y: 530, delivery: [5, 2], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_client(x: 435, y: 718, delivery: [3, 1], tw_early: 8400, tw_late: 15_300, service_duration: 420)
        |> Model.add_client(x: 1191, y: 639, delivery: [5, 1], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        # capacity: [10, 2] - dimension 2 is the bottleneck
        |> Model.add_vehicle_type(num_available: 10, capacity: [10, 2], tw_early: 0, tw_late: 45_000)
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([distances])

      stop = StoppingCriteria.max_iterations(10)
      assert {:ok, minimised_type} = MinimiseFleet.minimise(model, stop)

      # Dimension 1: ceil(18/10) = 2
      # Dimension 2: 1+2+1+1=5, ceil(5/2) = 3
      # Lower bound = max(2, 3) = 3
      assert minimised_type.num_available >= 3
    end

    test "multi-trip instance reduces to single vehicle" do
      # When vehicle can make multiple trips, fewer vehicles needed
      # Vehicle capacity 10, demands 5+5+3+5=18
      # With 1 reload (2 trips), effective capacity = 20
      # So 1 vehicle with 2 trips can handle all demand
      distances = build_ok_small_distances()

      model =
        Model.new()
        |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
        |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
        |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
        |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
        |> Model.add_vehicle_type(
          num_available: 3,
          capacity: [10],
          tw_early: 0,
          tw_late: 45_000,
          reload_depots: [0],
          # Allows 2 trips (1 reload)
          max_reloads: 1
        )
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([distances])

      stop = StoppingCriteria.max_iterations(10)
      assert {:ok, minimised_type} = MinimiseFleet.minimise(model, stop)

      # With 2 trips, effective capacity = 20 > 18
      # So we should be able to use 1 vehicle
      assert minimised_type.num_available == 1
    end

    test "respects seed for reproducibility" do
      model = build_ok_small_model()
      stop = StoppingCriteria.max_iterations(5)

      {:ok, result1} = MinimiseFleet.minimise(model, stop, seed: 42)
      {:ok, result2} = MinimiseFleet.minimise(model, stop, seed: 42)

      assert result1.num_available == result2.num_available
    end

    test "minimise! returns VehicleType on success" do
      model = build_ok_small_model()
      stop = StoppingCriteria.max_iterations(10)

      vehicle_type = MinimiseFleet.minimise!(model, stop)

      # Should be a VehicleType struct
      assert %ExVrp.VehicleType{} = vehicle_type
      assert vehicle_type.num_available <= 3
    end
  end

  describe "lower bound computation" do
    test "cannot go below lower bound" do
      # Create a simple instance where lower bound is clearly 2
      distances = [
        [0, 100, 100],
        [100, 0, 100],
        [100, 100, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_client(x: 100, y: 0, delivery: [10])
        |> Model.add_client(x: 0, y: 100, delivery: [10])
        |> Model.add_vehicle_type(num_available: 5, capacity: [10])
        |> Model.set_distance_matrices([distances])
        |> Model.set_duration_matrices([distances])

      # Each client needs 10, capacity is 10, so need 2 vehicles minimum
      stop = StoppingCriteria.max_iterations(50)
      {:ok, minimised} = MinimiseFleet.minimise(model, stop)

      # Lower bound is ceil(20/10) = 2
      assert minimised.num_available >= 2
    end
  end

  # Helper functions

  defp build_ok_small_model do
    distances = build_ok_small_distances()

    Model.new()
    |> Model.add_depot(x: 2334, y: 726, tw_early: 0, tw_late: 45_000)
    |> Model.add_client(x: 226, y: 1297, delivery: [5], tw_early: 15_600, tw_late: 22_500, service_duration: 360)
    |> Model.add_client(x: 590, y: 530, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
    |> Model.add_client(x: 435, y: 718, delivery: [3], tw_early: 8400, tw_late: 15_300, service_duration: 420)
    |> Model.add_client(x: 1191, y: 639, delivery: [5], tw_early: 12_000, tw_late: 19_500, service_duration: 360)
    |> Model.add_vehicle_type(num_available: 3, capacity: [10], tw_early: 0, tw_late: 45_000)
    |> Model.set_distance_matrices([distances])
    |> Model.set_duration_matrices([distances])
  end

  defp build_ok_small_distances do
    [
      [0, 1544, 1944, 1931, 1476],
      [1726, 0, 1992, 1427, 1593],
      [1965, 1975, 0, 621, 1090],
      [2063, 1433, 647, 0, 818],
      [1475, 1594, 1090, 828, 0]
    ]
  end
end

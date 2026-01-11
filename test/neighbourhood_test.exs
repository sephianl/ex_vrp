defmodule ExVrp.NeighbourhoodTest do
  @moduledoc """
  Tests for compute_neighbours, ported from PyVRP's test_neighbourhood.py.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Neighbourhood
  alias ExVrp.NeighbourhoodParams

  @moduletag :nif_required

  # ---------------------------------------------------------------------------
  # NeighbourhoodParams Tests
  # ---------------------------------------------------------------------------

  describe "NeighbourhoodParams" do
    test "raises for empty neighbourhoods (num_neighbours <= 0)" do
      assert_raise ArgumentError, ~r/num_neighbours <= 0/, fn ->
        NeighbourhoodParams.new(num_neighbours: 0)
      end

      assert_raise ArgumentError, ~r/num_neighbours <= 0/, fn ->
        NeighbourhoodParams.new(num_neighbours: -1)
      end
    end

    test "does not raise for valid arguments" do
      # Non-empty neighbourhood structure
      assert %NeighbourhoodParams{} =
               NeighbourhoodParams.new(
                 weight_wait_time: 20.0,
                 weight_time_warp: 20.0,
                 num_neighbours: 1,
                 symmetric_proximity: true,
                 symmetric_neighbours: false
               )

      # No weights for wait time or time warp should be OK
      assert %NeighbourhoodParams{} =
               NeighbourhoodParams.new(
                 weight_wait_time: 0.0,
                 weight_time_warp: 0.0,
                 num_neighbours: 1
               )
    end

    test "has correct defaults" do
      params = NeighbourhoodParams.new()
      assert params.weight_wait_time == 0.2
      assert params.weight_time_warp == 1.0
      assert params.num_neighbours == 60
      assert params.symmetric_proximity == true
      assert params.symmetric_neighbours == false
    end
  end

  # ---------------------------------------------------------------------------
  # compute_neighbours Tests
  # ---------------------------------------------------------------------------

  describe "compute_neighbours" do
    test "returns correct structure" do
      {:ok, problem_data} = create_small_problem()
      params = NeighbourhoodParams.new(num_neighbours: 2)

      neighbours = Neighbourhood.compute_neighbours(problem_data, params)

      # Should have one list per location
      # 1 depot + 4 clients
      assert length(neighbours) == 5

      # First entry (depot) should be empty
      assert Enum.at(neighbours, 0) == []

      # Client entries should have neighbours
      for i <- 1..4 do
        nbrs = Enum.at(neighbours, i)
        assert is_list(nbrs)
        # Each client should have at most num_neighbours neighbours
        assert length(nbrs) <= 2
        # Neighbours should be client indices (not depots)
        assert Enum.all?(nbrs, fn j -> j >= 1 end)
        # Should not include self
        refute i in nbrs
      end
    end

    test "neighbours are sorted by proximity" do
      {:ok, problem_data} = create_line_problem()
      # With zero wait/time_warp weights, proximity = distance
      params =
        NeighbourhoodParams.new(
          weight_wait_time: 0.0,
          weight_time_warp: 0.0,
          num_neighbours: 10
        )

      neighbours = Neighbourhood.compute_neighbours(problem_data, params)

      # For client at x=10 (index 1), closest should be client at x=20 (index 2)
      # Then x=30 (index 3), x=40 (index 4)
      assert Enum.at(neighbours, 1) == [2, 3, 4]

      # For client at x=40 (index 4), closest should be x=30 (index 3)
      # Then x=20 (index 2), x=10 (index 1)
      assert Enum.at(neighbours, 4) == [3, 2, 1]
    end

    test "symmetric neighbours" do
      {:ok, problem_data} = create_small_problem()

      # Without symmetric neighbours
      params_asym =
        NeighbourhoodParams.new(
          num_neighbours: 1,
          symmetric_neighbours: false
        )

      asym_neighbours = Neighbourhood.compute_neighbours(problem_data, params_asym)

      # With symmetric neighbours: if (i, j) is in, then so is (j, i)
      params_sym =
        NeighbourhoodParams.new(
          num_neighbours: 1,
          symmetric_neighbours: true
        )

      sym_neighbours = Neighbourhood.compute_neighbours(problem_data, params_sym)

      # Check symmetry
      for {nbrs, i} <- Enum.with_index(sym_neighbours) do
        for j <- nbrs do
          assert i in Enum.at(sym_neighbours, j),
                 "Expected #{i} in neighbours of #{j} for symmetry"
        end
      end

      # Symmetric should have >= neighbours than asymmetric
      for i <- 1..4 do
        assert length(Enum.at(sym_neighbours, i)) >= length(Enum.at(asym_neighbours, i))
      end
    end

    test "more neighbours than instance size" do
      {:ok, problem_data} = create_small_problem()
      num_clients = 4

      # Request more neighbours than exist
      params = NeighbourhoodParams.new(num_neighbours: 100)
      neighbours = Neighbourhood.compute_neighbours(problem_data, params)

      # Each client should have all other clients as neighbours
      for i <- 1..4 do
        nbrs = Enum.at(neighbours, i)
        assert length(nbrs) == num_clients - 1
      end
    end

    test "proximity with prizes" do
      {:ok, problem_data} = create_prize_problem()

      params =
        NeighbourhoodParams.new(
          weight_wait_time: 0.0,
          weight_time_warp: 0.0,
          num_neighbours: 2
        )

      neighbours = Neighbourhood.compute_neighbours(problem_data, params)

      # Client 1 (index 1) has high prize, client 2 (index 2) has low prize
      # Both are at same distance from client 3, but client 1 should be preferred
      # Check that client 1 appears more often in neighbourhoods
      count_1 = Enum.count(neighbours, fn nbrs -> 1 in nbrs end)
      count_2 = Enum.count(neighbours, fn nbrs -> 2 in nbrs end)

      assert count_1 >= count_2,
             "High-prize client should be in more neighbourhoods"
    end

    test "multiple routing profiles" do
      {:ok, problem_data} = create_multi_profile_problem()

      params =
        NeighbourhoodParams.new(
          weight_wait_time: 0.0,
          weight_time_warp: 0.0,
          num_neighbours: 2
        )

      # Should use the profile with lower costs for each vehicle type
      neighbours = Neighbourhood.compute_neighbours(problem_data, params)

      # Basic check: should return valid structure
      # 1 depot + 3 clients
      assert length(neighbours) == 4
      assert Enum.at(neighbours, 0) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Test Fixtures
  # ---------------------------------------------------------------------------

  defp create_small_problem do
    # 4 clients in a square pattern
    Model.new()
    |> Model.add_depot(x: 0, y: 0)
    |> Model.add_client(x: 10, y: 0, delivery: [10])
    |> Model.add_client(x: 10, y: 10, delivery: [10])
    |> Model.add_client(x: 0, y: 10, delivery: [10])
    |> Model.add_client(x: 5, y: 5, delivery: [10])
    |> Model.add_vehicle_type(num_available: 1, capacity: [100])
    |> Model.to_problem_data()
  end

  defp create_line_problem do
    # 4 clients in a line at x = 10, 20, 30, 40
    Model.new()
    |> Model.add_depot(x: 0, y: 0)
    |> Model.add_client(x: 10, y: 0, delivery: [10])
    |> Model.add_client(x: 20, y: 0, delivery: [10])
    |> Model.add_client(x: 30, y: 0, delivery: [10])
    |> Model.add_client(x: 40, y: 0, delivery: [10])
    |> Model.add_vehicle_type(num_available: 1, capacity: [100])
    |> Model.to_problem_data()
  end

  defp create_prize_problem do
    # 3 clients: one with high prize, one with low prize, one to test from
    Model.new()
    |> Model.add_depot(x: 0, y: 0)
    # High prize
    |> Model.add_client(x: 10, y: 0, delivery: [10], prize: 100)
    # Low prize (same dist)
    |> Model.add_client(x: 10, y: 1, delivery: [10], prize: 1)
    # Test client
    |> Model.add_client(x: 20, y: 0, delivery: [10])
    |> Model.add_vehicle_type(num_available: 1, capacity: [100])
    |> Model.to_problem_data()
  end

  defp create_multi_profile_problem do
    # 3 clients with 2 profiles
    model =
      Model.new()
      |> Model.add_depot(x: 0, y: 0)
      |> Model.add_client(x: 10, y: 0, delivery: [10])
      |> Model.add_client(x: 20, y: 0, delivery: [10])
      |> Model.add_client(x: 30, y: 0, delivery: [10])

    # Add vehicle type with profile 0
    model =
      Model.add_vehicle_type(model,
        num_available: 1,
        capacity: [100],
        profile: 0,
        unit_distance_cost: 1,
        unit_duration_cost: 0
      )

    Model.to_problem_data(model)
  end
end

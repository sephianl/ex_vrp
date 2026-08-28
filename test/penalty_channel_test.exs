defmodule ExVrp.PenaltyChannelTest do
  @moduledoc """
  Behavioural tests for the per-profile penalty channel.

  Penalties are per-(profile, location) costs in the objective, charged once
  per visited location. They are soft: a large enough prize outbids them.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solution
  alias ExVrp.Solver

  defp solve(model) do
    Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(500))
  end

  # One depot, one optional client, one vehicle. The client sits 10 units
  # away, so serving it costs 20 in distance.
  defp base_model(prize) do
    Model.new()
    |> Model.add_depot(tw_late: 1000)
    |> Model.add_client(
      delivery: [0],
      service_duration: 0,
      tw_early: 0,
      tw_late: 1000,
      required: false,
      prize: prize
    )
    |> Model.add_vehicle_type(
      num_available: 1,
      capacity: [100],
      unit_distance_cost: 1
    )
    |> Model.set_distance_matrices([[[0, 10], [10, 0]]])
    |> Model.set_duration_matrices([[[0, 10], [10, 0]]])
  end

  test "a model with no penalties set behaves as before" do
    {:ok, result} = solve(base_model(1000))

    assert Solution.num_clients(result.best) == 1
    assert Solution.penalty_cost(result.best) == 0
  end

  test "a penalty below the prize still leaves the client served" do
    model = Model.set_penalties(base_model(1000), [[0, 100]])

    {:ok, result} = solve(model)

    assert Solution.num_clients(result.best) == 1
    assert Solution.penalty_cost(result.best) == 100
  end

  test "a penalty above the prize makes the client not worth serving" do
    model = Model.set_penalties(base_model(1000), [[0, 5000]])

    {:ok, result} = solve(model)

    assert Solution.num_clients(result.best) == 0
    assert Solution.penalty_cost(result.best) == 0
  end

  describe "penalties under local search" do
    # The tests above are too small for local search to do real work: with one
    # client there is no move whose delta could be wrong. This one has enough
    # clients and vehicles that relocate and exchange moves fire repeatedly,
    # which is what exercises SegmentBefore/SegmentAfter/SegmentBetween
    # penalty() and Proposal::penalty(). Build with assertions enabled (drop
    # -DNDEBUG) and LocalSearch's `costAfter == costBefore + deltaCost` check
    # turns any segment-penalty error into a hard failure.
    test "every client is served and the penalty total is exact" do
      n = 11
      locations = 0..(n - 1)

      matrix =
        for i <- locations do
          for j <- locations, do: abs(i - j) * 10
        end

      # Depot is free; odd-indexed clients cost 300 each. Five of the ten
      # clients are penalised, so a correct solve reports exactly 1500.
      penalties = for i <- locations, do: if(i > 0 and rem(i, 2) == 1, do: 300, else: 0)

      model =
        Enum.reduce(1..(n - 1), Model.add_depot(Model.new(), tw_late: 100_000), fn _i, acc ->
          Model.add_client(acc,
            delivery: [1],
            service_duration: 0,
            tw_early: 0,
            tw_late: 100_000,
            required: false,
            prize: 100_000
          )
        end)

      model =
        model
        |> Model.add_vehicle_type(
          num_available: 2,
          capacity: [100],
          unit_distance_cost: 1,
          time_windows: [{0, 100_000}]
        )
        |> Model.set_distance_matrices([matrix])
        |> Model.set_duration_matrices([matrix])
        |> Model.set_penalties([penalties])

      {:ok, result} = solve(model)

      assert Solution.num_clients(result.best) == 10
      assert Solution.penalty_cost(result.best) == 1500
    end
  end

  describe "cross-profile penalties" do
    # Two vehicles on two profiles with identical matrices. The client is
    # free on profile 0 and heavily penalised on profile 1, so it must end
    # up on the profile-0 vehicle. This is the case that catches a broken
    # SegmentBetween::penalty, since moving the client between routes is
    # the only way the solver can discover the cheaper profile.
    test "a client is routed to the profile where it is not penalised" do
      matrix = [
        [0, 10, 10],
        [10, 0, 10],
        [10, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(tw_late: 1000)
        |> Model.add_client(
          delivery: [0],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          delivery: [0],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          unit_distance_cost: 1,
          profile: 0
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          unit_distance_cost: 1,
          profile: 1
        )
        |> Model.set_distance_matrices([matrix, matrix])
        |> Model.set_duration_matrices([matrix, matrix])
        # Location 1 is free on profile 0, punitive on profile 1.
        |> Model.set_penalties([[0, 0, 0], [0, 50_000, 0]])

      {:ok, result} = solve(model)
      solution = result.best

      assert Solution.num_clients(solution) == 2
      assert Solution.penalty_cost(solution) == 0
    end

    # The two-client case above is too small to detect a *wrong* value in
    # SegmentBetween's cross-profile branch: the branch runs, but no move it
    # misprices flips a decision. This one has enough clients on each profile
    # that inter-route moves cross profiles repeatedly, so a miscount there
    # changes which vehicle ends up carrying the penalised clients.
    test "penalised clients concentrate on the profile that does not charge them" do
      n = 13
      locations = 0..(n - 1)

      matrix =
        for i <- locations do
          for j <- locations, do: abs(i - j) * 10
        end

      # Clients 1..6 are free on profile 0 and expensive on profile 1;
      # clients 7..12 are the other way round. A correct solve puts each
      # group on its free profile and reports zero penalty.
      profile0 = for i <- locations, do: if(i >= 7, do: 1000, else: 0)
      profile1 = for i <- locations, do: if(i >= 1 and i <= 6, do: 1000, else: 0)

      model =
        Enum.reduce(1..(n - 1), Model.add_depot(Model.new(), tw_late: 100_000), fn _i, acc ->
          Model.add_client(acc,
            delivery: [1],
            service_duration: 0,
            tw_early: 0,
            tw_late: 100_000,
            required: false,
            prize: 100_000
          )
        end)

      model =
        model
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          unit_distance_cost: 1,
          profile: 0,
          time_windows: [{0, 100_000}]
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          unit_distance_cost: 1,
          profile: 1,
          time_windows: [{0, 100_000}]
        )
        |> Model.set_distance_matrices([matrix, matrix])
        |> Model.set_duration_matrices([matrix, matrix])
        |> Model.set_penalties([profile0, profile1])

      {:ok, result} = solve(model)

      assert Solution.num_clients(result.best) == 12
      assert Solution.penalty_cost(result.best) == 0
    end
  end
end

defmodule ExVrp.OscillationPreventionTest do
  @moduledoc """
  Tests that verify the oscillation prevention fix for prize-collecting.

  The bug: Optional clients with high prizes could oscillate infinitely:
  - Insert client A (appears improving due to prize)
  - Remove client B (appears improving due to prize)
  - Repeat forever

  The fix: applyOptionalClientMoves() now only runs when:
  - It's the first iteration (lastTested == -1), OR
  - The client's route was updated since last test

  This prevents immediate reversals while still allowing legitimate improvements.

  Oscillation is detected by iteration count, not elapsed time. A search that
  oscillates stalls inside an iteration and gets cut off by `max_runtime` having
  completed only a handful of them; a healthy one finishes its whole
  `max_iterations` budget.

  `max_runtime` is only a backstop against a hang, so it is set orders of
  magnitude above the real work: a 300-seed sweep of the first model completes
  all iterations in 9-90ms, so a 30s cap cannot bind on a healthy search no
  matter how contended the machine is. Earlier revisions used a 2s cap, which
  turned the iteration count back into a load measurement — under `mix check`
  this test once reported 76/100 iterations while every iteration was itself
  healthy.
  """

  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solver

  test "high prize clients converge without oscillating" do
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_vehicle_type(num_available: 2, capacity: [100])

    # Add several optional clients with very high prizes
    # These prizes make insert/remove both appear "improving"
    model =
      1..10
      |> Enum.reduce(model, fn _i, acc ->
        Model.add_client(acc,
          delivery: [10],
          required: false,
          # Very high prize
          prize: 100_000,
          service_duration: 300
        )
      end)
      |> Model.set_euclidean_matrices([{0, 0} | for(i <- 1..10, do: {i * 5.0, 0.0})])

    {:ok, result} =
      Solver.solve(model,
        max_iterations: 100,
        max_runtime: 30_000,
        num_starts: 1
      )

    assert result.best
    assert result.num_iterations <= 100

    assert result.num_iterations >= 90,
           "Only #{result.num_iterations}/100 iterations before the 30s timeout cut in (possible oscillation)"
  end

  test "prize-collecting still works correctly after oscillation fix" do
    # Verify the fix doesn't break normal prize-collecting behavior
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_vehicle_type(num_available: 1, capacity: [50])
      |> Model.add_client(delivery: [20], required: false, prize: 1000)
      |> Model.add_client(delivery: [20], required: false, prize: 2000)
      |> Model.add_client(delivery: [20], required: false, prize: 500)
      |> Model.set_euclidean_matrices([{0, 0}, {10, 0}, {20, 0}, {30, 0}])

    {:ok, result} = Solver.solve(model, max_iterations: 50)

    # Should find a solution with at least one optional client
    # (Client 2 with prize 2000 should be selected given capacity constraint)
    routes = ExVrp.Solution.routes(result.best)
    assert routes != []

    # Verify solution is valid
    assert result.best
    assert result.best.distance >= 0
  end

  test "oscillation prevention allows legitimate improvements" do
    # Verify that the fix doesn't prevent legitimate multi-step improvements
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_vehicle_type(num_available: 2, capacity: [100])

    model =
      1..8
      |> Enum.reduce(model, fn i, acc ->
        prize = if rem(i, 2) == 0, do: 5000, else: 1000

        Model.add_client(acc,
          delivery: [10],
          required: false,
          prize: prize,
          service_duration: 100
        )
      end)
      |> Model.set_euclidean_matrices([{0, 0} | for(i <- 1..8, do: {i * 10.0, 0.0})])

    {:ok, result} = Solver.solve(model, max_iterations: 100)

    # Should find a good solution (selecting high-prize clients)
    assert result.best
    assert result.num_iterations > 0

    # Solution should include some clients
    routes = ExVrp.Solution.routes(result.best)
    total_clients = Enum.sum(Enum.map(routes, fn route -> length(route.visits) end))
    assert total_clients > 0, "Should visit at least some clients"
  end

  test "search completes even with pathological prize values" do
    # Extreme test: very high prizes that maximize oscillation risk
    model =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_vehicle_type(num_available: 3, capacity: [100])

    # coordinates drawn first so the RNG sequence matches the pre-migration order
    coordinates = for _i <- 1..20, do: {:rand.uniform() * 100, :rand.uniform() * 100}

    model =
      1..20
      |> Enum.reduce(model, fn _i, acc ->
        Model.add_client(acc,
          delivery: [5],
          required: false,
          # Extremely high prize
          prize: 1_000_000,
          service_duration: 300
        )
      end)
      |> Model.set_euclidean_matrices([{0, 0} | coordinates])

    {:ok, result} =
      Solver.solve(model,
        max_iterations: 100,
        max_runtime: 30_000,
        seed: 12_345,
        num_starts: 1
      )

    assert result.best

    assert result.num_iterations >= 90,
           "Only #{result.num_iterations}/100 iterations before the 30s timeout cut in (oscillation detected)"
  end
end

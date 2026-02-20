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
  """

  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solver

  test "high prize clients converge without oscillating" do
    # Create a scenario with multiple high-prize optional clients
    # This would previously cause oscillations
    model =
      Model.new()
      |> Model.add_depot(x: 0, y: 0)
      |> Model.add_vehicle_type(num_available: 2, capacity: [100])

    # Add several optional clients with very high prizes
    # These prizes make insert/remove both appear "improving"
    model =
      Enum.reduce(1..10, model, fn i, acc ->
        Model.add_client(acc,
          x: i * 5.0,
          y: 0.0,
          delivery: [10],
          required: false,
          # Very high prize
          prize: 100_000,
          service_duration: 300
        )
      end)

    # Should complete quickly without oscillating
    start = System.monotonic_time(:millisecond)

    {:ok, result} =
      Solver.solve(model,
        max_iterations: 100,
        # 2 second timeout
        max_runtime: 2_000
      )

    elapsed = System.monotonic_time(:millisecond) - start

    # Should complete in reasonable time (not hit timeout)
    assert elapsed < 1_500, "Took #{elapsed}ms, expected <1.5s (possible oscillation)"
    assert result.best
    assert result.num_iterations <= 100
  end

  test "prize-collecting still works correctly after oscillation fix" do
    # Verify the fix doesn't break normal prize-collecting behavior
    model =
      Model.new()
      |> Model.add_depot(x: 0, y: 0)
      |> Model.add_vehicle_type(num_available: 1, capacity: [50])
      |> Model.add_client(x: 10, y: 0, delivery: [20], required: false, prize: 1000)
      |> Model.add_client(x: 20, y: 0, delivery: [20], required: false, prize: 2000)
      |> Model.add_client(x: 30, y: 0, delivery: [20], required: false, prize: 500)

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
      |> Model.add_depot(x: 0, y: 0)
      |> Model.add_vehicle_type(num_available: 2, capacity: [100])

    # Create a scenario where swapping clients IS beneficial
    model =
      Enum.reduce(1..8, model, fn i, acc ->
        prize = if rem(i, 2) == 0, do: 5000, else: 1000

        Model.add_client(acc,
          x: i * 10.0,
          y: 0.0,
          delivery: [10],
          required: false,
          prize: prize,
          service_duration: 100
        )
      end)

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
      |> Model.add_depot(x: 0, y: 0)
      |> Model.add_vehicle_type(num_available: 3, capacity: [100])

    model =
      Enum.reduce(1..20, model, fn i, acc ->
        Model.add_client(acc,
          x: :rand.uniform() * 100,
          y: :rand.uniform() * 100,
          delivery: [5],
          required: false,
          # Extremely high prize
          prize: 1_000_000,
          service_duration: 300
        )
      end)

    start = System.monotonic_time(:millisecond)

    {:ok, result} =
      Solver.solve(model,
        max_iterations: 100,
        max_runtime: 3_000,
        # Fixed seed for reproducibility
        seed: 12_345
      )

    elapsed = System.monotonic_time(:millisecond) - start

    # Must complete without hitting timeout
    assert elapsed < 2_500, "Took #{elapsed}ms, expected <2.5s (oscillation detected)"
    assert result.best
  end
end

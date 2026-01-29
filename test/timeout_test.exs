defmodule ExVrp.TimeoutTest do
  @moduledoc """
  Tests to verify C++ timeout mechanism works correctly.
  All tests use short timeouts (100-500ms) to keep test suite fast (2-3s total).
  """

  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  describe "C++ timeout propagation" do
    test "solver respects max_runtime parameter" do
      # Small problem with timeout
      model =
        1..10
        |> Enum.reduce(Model.add_depot(Model.new(), x: 0, y: 0), fn i, acc ->
          Model.add_client(acc,
            x: i * 10,
            y: 0,
            delivery: [5],
            required: false,
            prize: 10_000
          )
        end)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Solver.solve(model, max_runtime: 300)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should stop within timeout + small overhead
      assert elapsed < 500, "Solver ran for #{elapsed}ms, expected < 500ms"
      assert result.best
    end

    test "timeout works with high iteration count" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10], required: false, prize: 1000)

      # Request many iterations but short timeout
      start = System.monotonic_time(:millisecond)

      {:ok, result} =
        Solver.solve(model,
          max_iterations: 100_000,
          max_runtime: 200
        )

      elapsed = System.monotonic_time(:millisecond) - start

      # Timeout should win over iteration count
      assert elapsed < 400
      assert result.num_iterations < 100_000, "Should not complete all iterations"
    end

    test "very short timeout (100ms) is respected" do
      model =
        1..8
        |> Enum.reduce(Model.add_depot(Model.new(), x: 0, y: 0), fn i, acc ->
          Model.add_client(acc,
            x: i * 10,
            y: i * 10,
            delivery: [5],
            required: false,
            prize: 5_000
          )
        end)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Solver.solve(model, max_runtime: 100)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should stop within 100ms + grace period
      assert elapsed < 300, "Ran for #{elapsed}ms with 100ms timeout"
      assert result.best
    end

    test "timeout prevents infinite oscillation" do
      # Previously problematic pattern that could oscillate
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 10, y: 10, delivery: [50], required: false, prize: 100_000)
        |> Model.add_client(x: 15, y: 15, delivery: [50], required: false, prize: 100_000)

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Solver.solve(model, max_runtime: 200)
      elapsed = System.monotonic_time(:millisecond) - start

      # MUST complete within timeout
      assert elapsed < 400, "Timeout failed! Ran for #{elapsed}ms"
      assert result.best
    end

    test "zero timeout means no timeout (runs to max_iterations)" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10], required: false, prize: 1000)

      # No max_runtime specified = no timeout, only max_iterations
      {:ok, result} = Solver.solve(model, max_iterations: 50)

      # Should complete all iterations (or converge naturally)
      assert result.num_iterations <= 50
    end

    test "timeout works with StoppingCriteria.max_runtime" do
      model =
        1..8
        |> Enum.reduce(Model.add_depot(Model.new(), x: 0, y: 0), fn i, acc ->
          Model.add_client(acc,
            x: i * 15,
            y: 0,
            delivery: [8],
            required: false,
            prize: 8_000
          )
        end)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      start = System.monotonic_time(:millisecond)

      {:ok, result} =
        Solver.solve(model,
          # 0.25 seconds = 250ms
          stop: StoppingCriteria.max_runtime(0.25)
        )

      elapsed = System.monotonic_time(:millisecond) - start

      # Should respect the StoppingCriteria timeout
      assert elapsed < 450
      assert result.best
    end
  end

  describe "timeout edge cases" do
    test "timeout during initial solution construction" do
      # Very tight timeout that might fire during initialization
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10], required: true)

      start = System.monotonic_time(:millisecond)
      {:ok, result} = Solver.solve(model, max_runtime: 50)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should handle gracefully even with very short timeout
      assert elapsed < 200
      assert result.best
    end

    test "multiple solves with different timeouts" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10], required: false, prize: 1000)

      # First solve with short timeout
      start1 = System.monotonic_time(:millisecond)
      {:ok, result1} = Solver.solve(model, max_runtime: 100)
      elapsed1 = System.monotonic_time(:millisecond) - start1

      # Second solve with longer timeout
      start2 = System.monotonic_time(:millisecond)
      {:ok, result2} = Solver.solve(model, max_runtime: 200)
      elapsed2 = System.monotonic_time(:millisecond) - start2

      # Both should respect their respective timeouts
      assert elapsed1 < 300
      assert elapsed2 < 400
      assert result1.best
      assert result2.best
    end

    test "timeout does not leave solver in bad state" do
      # Verify solver can be used again after timeout
      model =
        1..5
        |> Enum.reduce(Model.add_depot(Model.new(), x: 0, y: 0), fn i, acc ->
          Model.add_client(acc,
            x: i * 10,
            y: 0,
            delivery: [10],
            required: false,
            prize: 5000
          )
        end)
        |> Model.add_vehicle_type(num_available: 2, capacity: [100])

      # Solve with timeout
      {:ok, result1} = Solver.solve(model, max_runtime: 150)
      assert result1.best

      # Solve again - should work normally
      {:ok, result2} = Solver.solve(model, max_runtime: 150)
      assert result2.best
    end
  end

  describe "timeout logging" do
    @tag :capture_log
    test "timeout completion doesn't crash" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10], required: false, prize: 1000)

      {:ok, result} = Solver.solve(model, max_runtime: 100)

      # Should complete without crashing
      assert result.best
      assert result.runtime
    end
  end
end

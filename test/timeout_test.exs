defmodule ExVrp.TimeoutTest do
  @moduledoc """
  Tests to verify timeout and stopping criteria work correctly.

  `result.runtime` is a wall-clock measurement, just taken inside the ILS loop
  rather than around the call, so it tracks machine load as much as solver
  behaviour — under `mix check` a 250ms budget has reported 892ms.

  These tests therefore pin `num_starts: 1` to remove cross-chain contention, and
  assert what a stopping criterion actually guarantees: that it *fired*, meaning
  the run ended well short of the default 10_000-iteration budget. Runtime
  ceilings are kept deliberately loose — they catch a criterion that is ignored
  entirely, not scheduling noise.
  """

  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  defp small_model do
    Model.new()
    |> Model.add_depot(x: 0, y: 0)
    |> Model.add_vehicle_type(num_available: 1, capacity: [100])
    |> Model.add_client(x: 10, y: 0, delivery: [10], required: false, prize: 1000)
  end

  defp medium_model do
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
  end

  describe "max_runtime" do
    test "solver completes within max_runtime" do
      {:ok, result} = Solver.solve(medium_model(), max_runtime: 300, num_starts: 1)
      assert result.best
      assert result.runtime <= 2_000
    end

    test "timeout wins over high iteration count" do
      {:ok, result} =
        Solver.solve(small_model(),
          max_iterations: 100_000,
          max_runtime: 200
        )

      assert result.best
      assert result.num_iterations < 100_000, "Should not complete all 100k iterations"
    end

    test "very short timeout (50ms) is handled gracefully" do
      {:ok, result} = Solver.solve(small_model(), max_runtime: 50)
      assert result.best
    end

    test "works with StoppingCriteria.max_runtime" do
      {:ok, result} =
        Solver.solve(medium_model(),
          stop: StoppingCriteria.max_runtime(0.25),
          num_starts: 1
        )

      assert result.best

      assert result.num_iterations < 10_000,
             "the runtime criterion never fired — the solve ran the full default iteration budget"

      assert result.runtime <= 2_000, "a 250ms budget took #{result.runtime}ms, far beyond scheduling noise"
    end

    test "stop: max_runtime respects timeout as accurately as max_runtime option" do
      timeout_ms = 300

      {:ok, via_option} = Solver.solve(medium_model(), max_runtime: timeout_ms, num_starts: 1)

      {:ok, via_stop} =
        Solver.solve(medium_model(), stop: StoppingCriteria.max_runtime(timeout_ms / 1000), num_starts: 1)

      # Both paths must bound the run; the ceiling is loose because it is wall clock
      assert via_option.runtime <= 2_000, "max_runtime: option took #{via_option.runtime}ms (budget: #{timeout_ms}ms)"
      assert via_stop.runtime <= 2_000, "stop: max_runtime took #{via_stop.runtime}ms (budget: #{timeout_ms}ms)"

      # Neither path may fall back to the default iteration budget
      assert via_option.num_iterations < 10_000
      assert via_stop.num_iterations < 10_000
    end
  end

  describe "max_iterations" do
    test "solver respects max_iterations" do
      {:ok, result} = Solver.solve(small_model(), max_iterations: 50)
      assert result.num_iterations <= 50
    end
  end

  describe "solver reuse" do
    test "multiple solves with different timeouts" do
      model = small_model()

      {:ok, result1} = Solver.solve(model, max_runtime: 100)
      {:ok, result2} = Solver.solve(model, max_runtime: 200)

      assert result1.best
      assert result2.best
    end

    test "solver can be reused after timeout" do
      model = medium_model()

      {:ok, result1} = Solver.solve(model, max_runtime: 150)
      {:ok, result2} = Solver.solve(model, max_runtime: 150)

      assert result1.best
      assert result2.best
    end
  end

  describe "edge cases" do
    test "timeout during initial solution construction" do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(x: 10, y: 0, delivery: [10], required: true)

      {:ok, result} = Solver.solve(model, max_runtime: 50)
      assert result.best
    end

    @tag :capture_log
    test "timeout completion doesn't crash" do
      {:ok, result} = Solver.solve(small_model(), max_runtime: 100)
      assert result.best
      assert result.runtime
    end
  end
end

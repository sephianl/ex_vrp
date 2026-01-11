defmodule ExVrp.PerturbationManagerTest do
  use ExUnit.Case, async: true

  alias ExVrp.PerturbationManager
  alias ExVrp.RNG

  @moduletag :nif_required

  describe "new/1" do
    test "creates with default params" do
      pm = PerturbationManager.new()
      assert pm.min_perturbations == 1
      assert pm.max_perturbations == 25
    end

    test "creates with custom params" do
      pm = PerturbationManager.new(min: 5, max: 10)
      assert pm.min_perturbations == 5
      assert pm.max_perturbations == 10
    end

    test "raises when min > max" do
      assert_raise ArgumentError, fn ->
        PerturbationManager.new(min: 10, max: 5)
      end
    end

    test "allows min == max" do
      pm = PerturbationManager.new(min: 0, max: 0)
      assert pm.min_perturbations == 0
      assert pm.max_perturbations == 0
    end
  end

  describe "num_perturbations/1" do
    test "initially set to min_perturbations" do
      pm = PerturbationManager.new(min: 5, max: 10)
      assert PerturbationManager.num_perturbations(pm) == 5
    end

    test "with default params starts at 1" do
      pm = PerturbationManager.new()
      assert PerturbationManager.num_perturbations(pm) == 1
    end
  end

  describe "shuffle/2" do
    test "picks new random number within bounds" do
      pm = PerturbationManager.new(min: 1, max: 10)
      rng = RNG.new(42)

      for _ <- 1..10 do
        pm = PerturbationManager.shuffle(pm, rng)
        num = PerturbationManager.num_perturbations(pm)
        assert num >= 1 and num <= 10
      end
    end

    test "with min == max always returns that value" do
      pm = PerturbationManager.new(min: 0, max: 0)
      rng = RNG.new(42)

      for _ <- 1..10 do
        pm = PerturbationManager.shuffle(pm, rng)
        assert PerturbationManager.num_perturbations(pm) == 0
      end
    end

    test "produces varied results with different seeds" do
      pm = PerturbationManager.new(min: 1, max: 100)

      results_seed_1 = collect_samples(pm, 42, 10)
      results_seed_2 = collect_samples(pm, 123, 10)

      # Different seeds should produce different sequences
      refute results_seed_1 == results_seed_2
    end
  end

  describe "randomness (PyVRP parity)" do
    test "uniform distribution over range" do
      # Based on test_num_perturbations_randomness from PyVRP
      pm = PerturbationManager.new(min: 1, max: 10)
      rng = RNG.new(42)

      # Collect a large sample
      samples =
        1..1000
        |> Enum.reduce({pm, []}, fn _, {pm, acc} ->
          pm = PerturbationManager.shuffle(pm, rng)
          num = PerturbationManager.num_perturbations(pm)
          {pm, [num | acc]}
        end)
        |> elem(1)

      # Should have drawn from [min, max] uniformly
      min_perturbs = pm.min_perturbations
      max_perturbs = pm.max_perturbations
      expected_avg = min_perturbs + (max_perturbs - min_perturbs) / 2

      assert Enum.min(samples) == min_perturbs
      assert Enum.max(samples) == max_perturbs

      # Average should be close to expected (with tolerance for randomness)
      actual_avg = Enum.sum(samples) / length(samples)
      assert_in_delta actual_avg, expected_avg, 0.5
    end
  end

  # Helper function
  defp collect_samples(pm, seed, n) do
    rng = RNG.new(seed)

    1..n
    |> Enum.reduce({pm, []}, fn _, {pm, acc} ->
      pm = PerturbationManager.shuffle(pm, rng)
      num = PerturbationManager.num_perturbations(pm)
      {pm, [num | acc]}
    end)
    |> elem(1)
  end
end

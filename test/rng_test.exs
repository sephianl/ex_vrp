defmodule ExVrp.RNGTest do
  use ExUnit.Case, async: true

  alias ExVrp.RNG

  @moduletag :nif_required

  describe "min/0 and max/0" do
    test "min returns 0" do
      assert RNG.min() == 0
    end

    test "max returns uint32 max" do
      # 2^32 - 1 = 4294967295
      assert RNG.max() == 4_294_967_295
    end
  end

  describe "call/1" do
    test "produces deterministic sequence with seed 42" do
      rng = RNG.new(42)

      {rng, value1} = RNG.call(rng)
      assert value1 == 2_386_648_076

      {_rng, value2} = RNG.call(rng)
      assert value2 == 1_236_469_084
    end

    test "produces deterministic sequence with seed 43" do
      rng = RNG.new(43)

      {rng, value1} = RNG.call(rng)
      assert value1 == 2_386_648_077

      {_rng, value2} = RNG.call(rng)
      assert value2 == 1_236_469_085
    end
  end

  describe "randint/2" do
    test "produces values in expected range with modulo behavior" do
      rng = RNG.new(42)

      # randint(high) should return __call__() % high
      {rng, value1} = RNG.randint(rng, 100)
      assert value1 == rem(2_386_648_076, 100)

      {_rng, value2} = RNG.randint(rng, 100)
      assert value2 == rem(1_236_469_084, 100)
    end
  end

  describe "rand/1" do
    @tag timeout: 60_000
    test "produces approximately uniform distribution" do
      rng = RNG.new(42)

      # Generate 10000 samples
      {_rng, samples} =
        Enum.reduce(1..10_000, {rng, []}, fn _, {rng_acc, samples_acc} ->
          {new_rng, value} = RNG.rand(rng_acc)
          {new_rng, [value | samples_acc]}
        end)

      # Compute statistics
      n = length(samples)
      sum = Enum.sum(samples)
      mean = sum / n

      variance =
        Enum.reduce(samples, 0.0, fn x, acc ->
          acc + (x - mean) * (x - mean)
        end) / n

      min_sample = Enum.min(samples)
      max_sample = Enum.max(samples)

      # Mean should be approximately 0.5
      assert_in_delta mean, 0.5, 0.02

      # Variance should be approximately 1/12 ≈ 0.0833
      assert_in_delta variance, 1 / 12, 0.01

      # All values should be in [0, 1]
      assert min_sample >= 0.0
      assert max_sample <= 1.0
    end
  end

  describe "from_state/1" do
    test "creates RNG with given state and returns same state" do
      state = [1, 2, 3, 4]
      {:ok, rng} = RNG.from_state(state)

      assert RNG.state(rng) == state
    end

    test "creates RNG with different state values" do
      state = [10, 14, 274, 83]
      {:ok, rng} = RNG.from_state(state)

      assert RNG.state(rng) == state
    end

    test "returns error for invalid state length" do
      assert {:error, _} = RNG.from_state([1, 2, 3])
      assert {:error, _} = RNG.from_state([1, 2, 3, 4, 5])
    end
  end

  describe "different seeds produce different sequences" do
    test "seed 1 and seed 2 produce different values" do
      rng1 = RNG.new(1)
      rng2 = RNG.new(2)

      {_, value1} = RNG.call(rng1)
      {_, value2} = RNG.call(rng2)

      assert value1 != value2
    end
  end
end

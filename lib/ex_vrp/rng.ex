defmodule ExVrp.RNG do
  @moduledoc """
  Random Number Generator (xoshiro128++) for deterministic, reproducible search.

  This module provides a functional wrapper around PyVRP's RandomNumberGenerator.
  All operations return a new RNG state, preserving immutability.

  ## Example

      rng = ExVrp.RNG.new(42)
      {rng, value} = ExVrp.RNG.call(rng)
      {rng, float} = ExVrp.RNG.rand(rng)
      {rng, int} = ExVrp.RNG.randint(rng, 100)

  """

  alias ExVrp.Native

  @type t :: reference()

  @doc """
  Creates a new RNG from a seed.

  ## Example

      rng = ExVrp.RNG.new(42)

  """
  @spec new(non_neg_integer()) :: t()
  def new(seed) when is_integer(seed) and seed >= 0 do
    Native.create_rng_from_seed_nif(seed)
  end

  @doc """
  Creates a new RNG from an explicit 4-element state.

  ## Example

      rng = ExVrp.RNG.from_state([1, 2, 3, 4])

  """
  @spec from_state([non_neg_integer()]) :: {:ok, t()} | {:error, term()}
  def from_state(state) when is_list(state) and length(state) == 4 do
    Native.create_rng_from_state_nif(state)
  end

  def from_state(_), do: {:error, "state must be a 4-element list of unsigned integers"}

  @doc """
  Returns the minimum value the RNG can produce (0).
  """
  @spec min() :: non_neg_integer()
  def min, do: Native.rng_min_nif()

  @doc """
  Returns the maximum value the RNG can produce (2^32 - 1).
  """
  @spec max() :: non_neg_integer()
  def max, do: Native.rng_max_nif()

  @doc """
  Generates the next random unsigned 32-bit integer.

  Returns `{new_rng, value}` where `value` is in the range `[min(), max()]`.

  ## Example

      {rng, value} = ExVrp.RNG.call(rng)

  """
  @spec call(t()) :: {t(), non_neg_integer()}
  def call(rng) do
    Native.rng_call_nif(rng)
  end

  @doc """
  Generates a random float uniformly distributed in [0, 1].

  Returns `{new_rng, value}`.

  ## Example

      {rng, float} = ExVrp.RNG.rand(rng)

  """
  @spec rand(t()) :: {t(), float()}
  def rand(rng) do
    Native.rng_rand_nif(rng)
  end

  @doc """
  Generates a random integer in the range [0, high).

  Returns `{new_rng, value}`.

  ## Example

      {rng, value} = ExVrp.RNG.randint(rng, 100)  # value in 0..99

  """
  @spec randint(t(), pos_integer()) :: {t(), non_neg_integer()}
  def randint(rng, high) when is_integer(high) and high > 0 do
    Native.rng_randint_nif(rng, high)
  end

  @doc """
  Returns the internal RNG state as a 4-element list.

  ## Example

      state = ExVrp.RNG.state(rng)  # [a, b, c, d]

  """
  @spec state(t()) :: [non_neg_integer()]
  def state(rng) do
    Native.rng_state_nif(rng)
  end
end

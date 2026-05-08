defmodule ExVrp.DynamicBitset do
  @moduledoc """
  A dynamic bitset for fast membership checks on integers.

  This is useful for tracking which clients are in a solution, which routes
  have been visited, etc. The bitset is immutable - all operations return
  a new bitset.

  The size is rounded up to the nearest multiple of 64 bits.

  ## Example

      bitset = ExVrp.DynamicBitset.new(128)
      bitset = ExVrp.DynamicBitset.set(bitset, 0, true)
      bitset = ExVrp.DynamicBitset.set(bitset, 64, true)
      ExVrp.DynamicBitset.count(bitset)  # => 2

  """

  alias ExVrp.Native

  @type t :: reference()

  @doc """
  Creates a new bitset with the given number of bits.

  The actual size is rounded up to the nearest multiple of 64.

  ## Example

      bitset = ExVrp.DynamicBitset.new(128)

  """
  @spec new(non_neg_integer()) :: t()
  def new(num_bits) when is_integer(num_bits) and num_bits >= 0 do
    Native.create_dynamic_bitset_nif(num_bits)
  end

  @doc """
  Returns the size (length) of the bitset.

  This is the actual allocated size (rounded up to 64-bit blocks).
  """
  @spec size(t()) :: non_neg_integer()
  def size(bitset) do
    Native.dynamic_bitset_len_nif(bitset)
  end

  @doc """
  Gets the bit at the given index.

  ## Example

      ExVrp.DynamicBitset.get(bitset, 0)  # => false

  """
  @spec get(t(), non_neg_integer()) :: boolean()
  def get(bitset, idx) when is_integer(idx) and idx >= 0 do
    Native.dynamic_bitset_get_nif(bitset, idx)
  end

  @doc """
  Sets the bit at the given index. Returns a new bitset.

  ## Example

      bitset = ExVrp.DynamicBitset.set(bitset, 0, true)

  """
  @spec set(t(), non_neg_integer(), boolean()) :: t()
  def set(bitset, idx, value) when is_integer(idx) and idx >= 0 and is_boolean(value) do
    Native.dynamic_bitset_set_bit_nif(bitset, idx, value)
  end

  @doc """
  Returns true if all bits are set.
  """
  @spec all?(t()) :: boolean()
  def all?(bitset) do
    Native.dynamic_bitset_all_nif(bitset)
  end

  @doc """
  Returns true if any bit is set.
  """
  @spec any?(t()) :: boolean()
  def any?(bitset) do
    Native.dynamic_bitset_any_nif(bitset)
  end

  @doc """
  Returns true if no bits are set.
  """
  @spec none?(t()) :: boolean()
  def none?(bitset) do
    Native.dynamic_bitset_none_nif(bitset)
  end

  @doc """
  Returns the number of set bits.
  """
  @spec count(t()) :: non_neg_integer()
  def count(bitset) do
    Native.dynamic_bitset_count_nif(bitset)
  end

  @doc """
  Sets all bits to 1. Returns a new bitset.
  """
  @spec set_all(t()) :: t()
  def set_all(bitset) do
    Native.dynamic_bitset_set_all_nif(bitset)
  end

  @doc """
  Resets all bits to 0. Returns a new bitset.
  """
  @spec reset_all(t()) :: t()
  def reset_all(bitset) do
    Native.dynamic_bitset_reset_all_nif(bitset)
  end

  @doc """
  Bitwise OR of two bitsets. Returns a new bitset.

  ## Example

      result = ExVrp.DynamicBitset.bit_or(bitset1, bitset2)

  """
  @spec bit_or(t(), t()) :: t()
  def bit_or(a, b) do
    Native.dynamic_bitset_or_nif(a, b)
  end

  @doc """
  Bitwise AND of two bitsets. Returns a new bitset.
  """
  @spec bit_and(t(), t()) :: t()
  def bit_and(a, b) do
    Native.dynamic_bitset_and_nif(a, b)
  end

  @doc """
  Bitwise XOR of two bitsets. Returns a new bitset.
  """
  @spec bit_xor(t(), t()) :: t()
  def bit_xor(a, b) do
    Native.dynamic_bitset_xor_nif(a, b)
  end

  @doc """
  Bitwise NOT of a bitset. Returns a new bitset.
  """
  @spec bit_not(t()) :: t()
  def bit_not(bitset) do
    Native.dynamic_bitset_not_nif(bitset)
  end

  @doc """
  Checks if two bitsets are equal.
  """
  @spec equal?(t(), t()) :: boolean()
  def equal?(a, b) do
    Native.dynamic_bitset_eq_nif(a, b)
  end
end

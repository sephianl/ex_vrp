defmodule ExVrp.DynamicBitsetTest do
  use ExUnit.Case, async: true

  alias ExVrp.DynamicBitset

  @moduletag :nif_required

  describe "size/1" do
    test "size 0 gives 0" do
      bitset = DynamicBitset.new(0)
      assert DynamicBitset.size(bitset) == 0
    end

    test "size 1 gives 64" do
      bitset = DynamicBitset.new(1)
      assert DynamicBitset.size(bitset) == 64
    end

    test "size 64 gives 64" do
      bitset = DynamicBitset.new(64)
      assert DynamicBitset.size(bitset) == 64
    end

    test "size 65 gives 128" do
      bitset = DynamicBitset.new(65)
      assert DynamicBitset.size(bitset) == 128
    end

    test "size 128 gives 128" do
      bitset = DynamicBitset.new(128)
      assert DynamicBitset.size(bitset) == 128
    end
  end

  describe "initialization" do
    test "starts with all zeros" do
      bitset = DynamicBitset.new(64)

      for idx <- 0..63 do
        refute DynamicBitset.get(bitset, idx)
      end

      assert DynamicBitset.count(bitset) == 0
    end
  end

  describe "equal?/2" do
    test "empty bitsets of same size are equal" do
      bitset1 = DynamicBitset.new(64)
      bitset2 = DynamicBitset.new(64)
      assert DynamicBitset.equal?(bitset1, bitset2)
    end

    test "bitsets with different bits are not equal" do
      bitset1 = DynamicBitset.new(64)
      bitset2 = DynamicBitset.set(DynamicBitset.new(64), 0, true)
      refute DynamicBitset.equal?(bitset1, bitset2)
    end
  end

  describe "get/2 and set/3" do
    test "setting and retrieving bits at boundaries" do
      bitset = DynamicBitset.new(128)
      indices = [0, 1, 63, 64, 126, 127]

      assert DynamicBitset.count(bitset) == 0

      # Set all bits at indices to true
      bitset =
        Enum.reduce(indices, bitset, fn idx, acc ->
          refute DynamicBitset.get(acc, idx)
          new_bitset = DynamicBitset.set(acc, idx, true)
          assert DynamicBitset.get(new_bitset, idx)
          new_bitset
        end)

      assert DynamicBitset.count(bitset) == length(indices)

      # Set all bits back to false
      bitset =
        Enum.reduce(indices, bitset, fn idx, acc ->
          assert DynamicBitset.get(acc, idx)
          new_bitset = DynamicBitset.set(acc, idx, false)
          refute DynamicBitset.get(new_bitset, idx)
          new_bitset
        end)

      assert DynamicBitset.count(bitset) == 0
    end
  end

  describe "all?/1, any?/1, none?/1" do
    test "empty bitset" do
      bitset = DynamicBitset.new(128)

      refute DynamicBitset.any?(bitset)
      assert DynamicBitset.none?(bitset)
      refute DynamicBitset.all?(bitset)
      assert DynamicBitset.all?(DynamicBitset.bit_not(bitset))
    end

    test "with one bit set" do
      bitset = DynamicBitset.set(DynamicBitset.new(128), 0, true)

      assert DynamicBitset.any?(bitset)
      refute DynamicBitset.none?(bitset)
      refute DynamicBitset.all?(bitset)
      refute DynamicBitset.all?(DynamicBitset.bit_not(bitset))
    end
  end

  describe "all?/1, any?/1, none?/1 with empty bitset" do
    test "size 0 bitset" do
      bitset = DynamicBitset.new(0)

      assert DynamicBitset.all?(bitset)
      assert DynamicBitset.none?(bitset)
      refute DynamicBitset.any?(bitset)
    end
  end

  describe "bit_or/2" do
    test "union of two bitsets" do
      bitset1 =
        128
        |> DynamicBitset.new()
        |> DynamicBitset.set(0, true)
        |> DynamicBitset.set(64, true)

      bitset2 =
        128
        |> DynamicBitset.new()
        |> DynamicBitset.set(0, true)
        |> DynamicBitset.set(65, true)

      result = DynamicBitset.bit_or(bitset1, bitset2)

      assert DynamicBitset.count(result) == 3
      assert DynamicBitset.get(result, 0)
      assert DynamicBitset.get(result, 64)
      assert DynamicBitset.get(result, 65)
    end
  end

  describe "bit_and/2" do
    test "intersection of two bitsets" do
      bitset1 =
        128
        |> DynamicBitset.new()
        |> DynamicBitset.set(0, true)
        |> DynamicBitset.set(64, true)

      bitset2 =
        128
        |> DynamicBitset.new()
        |> DynamicBitset.set(0, true)
        |> DynamicBitset.set(65, true)

      result = DynamicBitset.bit_and(bitset1, bitset2)

      assert DynamicBitset.count(result) == 1
      assert DynamicBitset.get(result, 0)
      refute DynamicBitset.get(result, 64)
      refute DynamicBitset.get(result, 65)
    end
  end

  describe "bit_xor/2" do
    test "symmetric difference of two bitsets" do
      bitset1 =
        128
        |> DynamicBitset.new()
        |> DynamicBitset.set(0, true)
        |> DynamicBitset.set(64, true)

      bitset2 =
        128
        |> DynamicBitset.new()
        |> DynamicBitset.set(0, true)
        |> DynamicBitset.set(65, true)

      result = DynamicBitset.bit_xor(bitset1, bitset2)

      assert DynamicBitset.count(result) == 2
      refute DynamicBitset.get(result, 0)
      assert DynamicBitset.get(result, 64)
      assert DynamicBitset.get(result, 65)
    end
  end

  describe "bit_not/1" do
    test "complement of empty bitset" do
      bitset = DynamicBitset.new(128)
      assert DynamicBitset.count(bitset) == 0

      inverted = DynamicBitset.bit_not(bitset)
      assert DynamicBitset.count(inverted) == 128

      # Clear two bits
      inverted =
        inverted
        |> DynamicBitset.set(0, false)
        |> DynamicBitset.set(127, false)

      # Inverting again should have 2 bits set
      assert DynamicBitset.count(DynamicBitset.bit_not(inverted)) == 2
    end
  end

  describe "set_all/1" do
    test "sets all bits to 1" do
      bitset = DynamicBitset.new(128)
      assert DynamicBitset.count(bitset) == 0

      bitset =
        bitset
        |> DynamicBitset.set(0, true)
        |> DynamicBitset.set(1, true)

      assert DynamicBitset.count(bitset) == 2

      bitset = DynamicBitset.set_all(bitset)
      assert DynamicBitset.count(bitset) == 128
    end
  end

  describe "reset_all/1" do
    test "resets all bits to 0" do
      bitset = DynamicBitset.new(128)
      assert DynamicBitset.count(bitset) == 0

      bitset =
        bitset
        |> DynamicBitset.set(0, true)
        |> DynamicBitset.set(1, true)

      assert DynamicBitset.count(bitset) == 2

      bitset = DynamicBitset.reset_all(bitset)
      assert DynamicBitset.count(bitset) == 0
    end
  end
end

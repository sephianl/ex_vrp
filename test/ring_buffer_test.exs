defmodule ExVrp.RingBufferTest do
  use ExUnit.Case, async: true

  alias ExVrp.RingBuffer

  describe "ring buffer operations" do
    test "new buffer has correct maxlen and length" do
      buffer = RingBuffer.new(2)
      assert RingBuffer.maxlen(buffer) == 2
      assert RingBuffer.length(buffer) == 0
    end

    test "append increases length up to maxlen" do
      buffer = RingBuffer.new(2)
      obj1 = make_ref()
      obj2 = make_ref()

      buffer = RingBuffer.append(buffer, obj1)
      assert RingBuffer.length(buffer) == 1
      # Peek at next slot - should be nil since we haven't set it yet
      assert RingBuffer.peek(buffer) == nil

      buffer = RingBuffer.append(buffer, obj2)
      assert RingBuffer.length(buffer) == 2
      # Now peek should return obj1 (next to be overwritten)
      assert RingBuffer.peek(buffer) == obj1
    end

    test "skip moves head without removing items" do
      buffer = RingBuffer.new(2)
      obj1 = make_ref()
      obj2 = make_ref()

      buffer =
        buffer
        |> RingBuffer.append(obj1)
        |> RingBuffer.append(obj2)

      assert RingBuffer.peek(buffer) == obj1

      buffer = RingBuffer.skip(buffer)
      assert RingBuffer.length(buffer) == 2
      assert RingBuffer.peek(buffer) == obj2
    end

    test "clear resets the buffer" do
      buffer = RingBuffer.new(2)
      obj1 = make_ref()
      obj2 = make_ref()

      buffer =
        buffer
        |> RingBuffer.append(obj1)
        |> RingBuffer.append(obj2)

      buffer = RingBuffer.clear(buffer)

      assert RingBuffer.maxlen(buffer) == 2
      assert RingBuffer.length(buffer) == 0
    end
  end
end

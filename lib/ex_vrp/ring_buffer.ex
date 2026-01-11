defmodule ExVrp.RingBuffer do
  @moduledoc """
  A fixed-size circular buffer for tracking recently inserted values.

  The ring buffer stores up to `maxlen` items. When full, new items
  overwrite the oldest ones. The `peek/1` function returns the value
  that would be overwritten by the next append, or `nil` if that slot
  hasn't been written yet.

  ## Example

      buffer = ExVrp.RingBuffer.new(2)
      buffer = ExVrp.RingBuffer.append(buffer, :a)
      buffer = ExVrp.RingBuffer.append(buffer, :b)
      ExVrp.RingBuffer.peek(buffer)  # => :a (next to be overwritten)

  """

  @type t :: %__MODULE__{
          maxlen: pos_integer(),
          buffer: list(),
          head: non_neg_integer(),
          size: non_neg_integer()
        }

  defstruct [:maxlen, :buffer, :head, :size]

  @doc """
  Creates a new ring buffer with the given maximum length.

  ## Example

      buffer = ExVrp.RingBuffer.new(3)

  """
  @spec new(pos_integer()) :: t()
  def new(maxlen) when is_integer(maxlen) and maxlen > 0 do
    %__MODULE__{
      maxlen: maxlen,
      buffer: List.duplicate(nil, maxlen),
      head: 0,
      size: 0
    }
  end

  @doc """
  Appends a value to the buffer.

  If the buffer is full, the oldest value is overwritten.
  """
  @spec append(t(), term()) :: t()
  def append(%__MODULE__{} = rb, value) do
    new_buffer = List.replace_at(rb.buffer, rb.head, value)
    new_head = rem(rb.head + 1, rb.maxlen)
    new_size = min(rb.size + 1, rb.maxlen)

    %{rb | buffer: new_buffer, head: new_head, size: new_size}
  end

  @doc """
  Peeks at the value in the next slot (the one that would be overwritten next).

  Returns `nil` if that slot hasn't been written to yet.
  """
  @spec peek(t()) :: term() | nil
  def peek(%__MODULE__{} = rb) do
    # If the buffer is not full, the next slot is unwritten (nil)
    # If it is full, the next slot is the oldest value (will be overwritten)
    if rb.size < rb.maxlen do
      nil
    else
      Enum.at(rb.buffer, rb.head)
    end
  end

  @doc """
  Skips to the next slot without writing anything.

  This moves the head pointer forward without changing the size.
  """
  @spec skip(t()) :: t()
  def skip(%__MODULE__{} = rb) do
    new_head = rem(rb.head + 1, rb.maxlen)
    %{rb | head: new_head}
  end

  @doc """
  Clears the buffer, resetting it to its initial state.
  """
  @spec clear(t()) :: t()
  def clear(%__MODULE__{maxlen: maxlen}) do
    new(maxlen)
  end

  @doc """
  Returns the maximum length of the buffer.
  """
  @spec maxlen(t()) :: pos_integer()
  def maxlen(%__MODULE__{maxlen: maxlen}), do: maxlen

  @doc """
  Returns the current number of items in the buffer.
  """
  @spec length(t()) :: non_neg_integer()
  def length(%__MODULE__{size: size}), do: size
end

defmodule ExVrp.Matrix do
  @moduledoc """
  The two forms a distance or duration matrix, or one row of it, takes in an `ExVrp.Model`:
  nested lists of integers, or one binary of little-endian signed 64-bit integers in row-major
  order.

  The solver copies a binary in without walking it, so it is the form for large matrices, and
  nothing here reads more than one row's worth of it.
  """

  @type t :: [[integer()]] | binary()
  @type row :: [integer()] | binary()

  @cell_bytes 8

  @doc "The matrix as one binary of little-endian int64s, row-major."
  @spec from_lists([[integer()]]) :: binary()
  def from_lists(rows), do: for(row <- rows, into: <<>>, do: row_from_list(row))

  @doc "The row as a binary of little-endian int64s."
  @spec row_from_list([integer()]) :: binary()
  def row_from_list(row), do: for(value <- row, into: <<>>, do: <<value::signed-little-64>>)

  @doc "The matrix as nested lists of rows."
  @spec to_lists(t()) :: [[integer()]]
  def to_lists(matrix) when is_list(matrix), do: matrix

  def to_lists(matrix) when is_binary(matrix) do
    row_bytes = side(matrix) * @cell_bytes
    for <<row::binary-size(^row_bytes) <- matrix>>, do: row_to_list(row)
  end

  @doc "The row as a list."
  @spec row_to_list(row()) :: [integer()]
  def row_to_list(row) when is_list(row), do: row
  def row_to_list(row) when is_binary(row), do: for(<<value::signed-little-64 <- row>>, do: value)

  @doc "Whether the matrix is `size` rows of `size` cells."
  @spec square?(term(), non_neg_integer()) :: boolean()
  def square?(matrix, size) when is_binary(matrix), do: byte_size(matrix) == size * size * @cell_bytes
  def square?(matrix, size) when is_list(matrix), do: length(matrix) == size and Enum.all?(matrix, &row?(&1, size))
  def square?(_matrix, _size), do: false

  @doc "Whether the row holds `size` cells."
  @spec row?(term(), non_neg_integer()) :: boolean()
  def row?(row, size) when is_binary(row), do: byte_size(row) == size * @cell_bytes
  def row?(row, size) when is_list(row), do: length(row) == size
  def row?(_row, _size), do: false

  @doc "Whether every cell on the diagonal of a square matrix is zero."
  @spec zero_diagonal?(t()) :: boolean()
  def zero_diagonal?(matrix) when is_binary(matrix) do
    size = side(matrix)
    Enum.all?(0..(size - 1)//1, &(binary_cell(matrix, &1 * size + &1) == 0))
  end

  def zero_diagonal?(matrix) when is_list(matrix) do
    matrix
    |> Enum.with_index()
    |> Enum.all?(fn {row, index} -> row_at(row, index) == 0 end)
  end

  @doc "The row's cell at `index`, 0-based."
  @spec row_at(row(), non_neg_integer()) :: integer()
  def row_at(row, index) when is_binary(row), do: binary_cell(row, index)
  def row_at(row, index) when is_list(row), do: Enum.at(row, index)

  @doc "The matrix with `count` zero columns and then `count` zero rows appended, in its own form."
  @spec pad(t(), non_neg_integer()) :: t()
  def pad(matrix, count) when is_binary(matrix) do
    size = side(matrix)
    row_bytes = size * @cell_bytes
    zero_row = zeros(size + count)
    padding = zeros(count)

    IO.iodata_to_binary([
      for(<<row::binary-size(^row_bytes) <- matrix>>, do: [row, padding]),
      List.duplicate(zero_row, count)
    ])
  end

  def pad(matrix, count) when is_list(matrix) do
    zero_row = List.duplicate(0, length(matrix) + count)
    Enum.map(matrix, &pad_row(&1, count)) ++ List.duplicate(zero_row, count)
  end

  @doc "The row with `count` zero cells appended, in its own form."
  @spec pad_row(row(), non_neg_integer()) :: row()
  def pad_row(row, count) when is_binary(row), do: row <> zeros(count)
  def pad_row(row, count) when is_list(row), do: row ++ List.duplicate(0, count)

  defp zeros(count), do: <<0::size(count * @cell_bytes * 8)>>

  defp side(matrix), do: matrix |> byte_size() |> div(@cell_bytes) |> :math.sqrt() |> round()

  defp binary_cell(binary, index) do
    <<value::signed-little-64>> = binary_part(binary, index * @cell_bytes, @cell_bytes)
    value
  end
end

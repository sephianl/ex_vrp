defmodule ExVrp.NeighbourhoodParams do
  @moduledoc """
  Configuration for calculating a granular neighbourhood.

  ## Attributes

  - `weight_wait_time` - Penalty weight given to the minimum wait time aspect
    of the proximity calculation. A large wait time indicates the clients are
    far apart in duration/time.
  - `weight_time_warp` - Penalty weight given to the minimum time warp aspect
    of the proximity calculation. A large time warp indicates the clients are
    far apart in duration/time.
  - `num_neighbours` - Number of other clients that are in each client's
    granular neighbourhood. This parameter determines the size of the overall
    neighbourhood.
  - `symmetric_proximity` - Whether to calculate a symmetric proximity matrix.
    This ensures edge (i, j) is given the same weight as (j, i).
  - `symmetric_neighbours` - Whether to symmetrise the neighbourhood structure.
    This ensures that when edge (i, j) is in, then so is (j, i). Note that
    this is *not* the same as `symmetric_proximity`.

  ## Example

      iex> params = ExVrp.NeighbourhoodParams.new()
      iex> params.weight_wait_time
      0.2
      iex> params.num_neighbours
      60

      iex> params = ExVrp.NeighbourhoodParams.new(num_neighbours: 40)
      iex> params.num_neighbours
      40

  """

  @type t :: %__MODULE__{
          weight_wait_time: float(),
          weight_time_warp: float(),
          num_neighbours: pos_integer(),
          symmetric_proximity: boolean(),
          symmetric_neighbours: boolean()
        }

  defstruct weight_wait_time: 0.2,
            weight_time_warp: 1.0,
            num_neighbours: 60,
            symmetric_proximity: true,
            symmetric_neighbours: false

  @doc """
  Creates a new NeighbourhoodParams with the given options.

  ## Options

  - `:weight_wait_time` - Penalty weight for wait time (default: 0.2)
  - `:weight_time_warp` - Penalty weight for time warp (default: 1.0)
  - `:num_neighbours` - Number of neighbours per client (default: 60)
  - `:symmetric_proximity` - Symmetrize proximity matrix (default: true)
  - `:symmetric_neighbours` - Symmetrize neighbourhood structure (default: false)

  ## Raises

  - `ArgumentError` when `num_neighbours` is non-positive.

  ## Examples

      iex> ExVrp.NeighbourhoodParams.new()
      %ExVrp.NeighbourhoodParams{
        weight_wait_time: 0.2,
        weight_time_warp: 1.0,
        num_neighbours: 60,
        symmetric_proximity: true,
        symmetric_neighbours: false
      }

      iex> ExVrp.NeighbourhoodParams.new(num_neighbours: 40, symmetric_neighbours: true)
      %ExVrp.NeighbourhoodParams{
        weight_wait_time: 0.2,
        weight_time_warp: 1.0,
        num_neighbours: 40,
        symmetric_proximity: true,
        symmetric_neighbours: true
      }

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    params = struct!(__MODULE__, opts)

    if params.num_neighbours <= 0 do
      raise ArgumentError, "num_neighbours <= 0 not understood."
    end

    params
  end
end

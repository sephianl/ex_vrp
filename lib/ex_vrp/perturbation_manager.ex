defmodule ExVrp.PerturbationManager do
  @moduledoc """
  Manages perturbation during local search.

  In each iteration, it applies a random number of perturbations that
  strengthen or weaken randomly selected neighbourhoods by inserting
  or removing clients.

  ## Example

      pm = ExVrp.PerturbationManager.new(min: 1, max: 25)
      assert pm.min_perturbations == 1
      assert pm.max_perturbations == 25

      # Initially set to min_perturbations
      assert ExVrp.PerturbationManager.num_perturbations(pm) == 1

      # Shuffle to pick a new random number
      rng = ExVrp.RNG.new(42)
      pm = ExVrp.PerturbationManager.shuffle(pm, rng)
      num = ExVrp.PerturbationManager.num_perturbations(pm)
      assert num >= 1 and num <= 25

  """

  alias ExVrp.Native

  @type t :: %__MODULE__{
          ref: reference(),
          min_perturbations: non_neg_integer(),
          max_perturbations: non_neg_integer()
        }

  defstruct [:ref, :min_perturbations, :max_perturbations]

  @doc """
  Creates a new PerturbationManager.

  ## Options

  - `:min` - Minimum number of perturbations (default: 1)
  - `:max` - Maximum number of perturbations (default: 25)

  ## Examples

      iex> pm = ExVrp.PerturbationManager.new()
      iex> pm.min_perturbations
      1
      iex> pm.max_perturbations
      25

      iex> pm = ExVrp.PerturbationManager.new(min: 5, max: 10)
      iex> pm.min_perturbations
      5

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    min = Keyword.get(opts, :min, 1)
    max = Keyword.get(opts, :max, 25)

    ref = Native.create_perturbation_manager_nif(min, max)

    %__MODULE__{
      ref: ref,
      min_perturbations: min,
      max_perturbations: max
    }
  end

  @doc """
  Returns the current number of perturbations to apply.

  Initially this is set to `min_perturbations`. Call `shuffle/2` to
  pick a new random value within the [min, max] range.
  """
  @spec num_perturbations(t()) :: non_neg_integer()
  def num_perturbations(%__MODULE__{ref: ref}) do
    Native.perturbation_manager_num_perturbations_nif(ref)
  end

  @doc """
  Shuffles to pick a new random number of perturbations.

  The new value is drawn uniformly from [min_perturbations, max_perturbations].

  ## Example

      pm = ExVrp.PerturbationManager.new(min: 1, max: 10)
      rng = ExVrp.RNG.new(42)
      pm = ExVrp.PerturbationManager.shuffle(pm, rng)
      num = ExVrp.PerturbationManager.num_perturbations(pm)
      assert num >= 1 and num <= 10

  """
  @spec shuffle(t(), reference()) :: t()
  def shuffle(%__MODULE__{ref: ref} = pm, rng) when is_reference(rng) do
    Native.perturbation_manager_shuffle_nif(ref, rng)
    pm
  end
end

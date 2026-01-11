defmodule ExVrp.StoppingCriteria do
  @moduledoc """
  Stopping criteria for controlling when the solver terminates.

  This is a port of PyVRP's stopping criteria. In PyVRP, criteria are called
  with `stop(best_cost)` and return a boolean. We provide both the struct-based
  API and a `to_stop_fn/1` that creates a closure matching PyVRP's interface.

  ## Available Criteria

  - `max_iterations/1` - Stop after N iterations
  - `max_runtime/1` - Stop after N seconds (float, like PyVRP)
  - `no_improvement/1` - Stop after N iterations without improvement
  - `first_feasible/0` - Stop when a feasible solution is found
  - `multiple_criteria/1` - Combine criteria (stops when ANY is met)

  ## Example

      # Stop after 1000 iterations OR 60 seconds
      stop = StoppingCriteria.multiple_criteria([
        StoppingCriteria.max_iterations(1000),
        StoppingCriteria.max_runtime(60.0)
      ])

      {:ok, result} = Solver.solve(model, stop: stop)

  """

  @type t :: %__MODULE__{
          type:
            :max_iterations
            | :max_runtime
            | :no_improvement
            | :multiple_criteria
            | :first_feasible,
          state: map()
        }

  @type stop_fn :: (non_neg_integer() -> boolean())

  defstruct [:type, :state]

  @doc """
  Creates a criterion that stops after a maximum number of iterations.

  Raises `ArgumentError` if max_iterations is negative.

  ## Example

      StoppingCriteria.max_iterations(1000)

  """
  @spec max_iterations(non_neg_integer()) :: t()
  def max_iterations(max) when is_integer(max) and max >= 0 do
    %__MODULE__{
      type: :max_iterations,
      state: %{max: max, current: 0}
    }
  end

  def max_iterations(max) when is_integer(max) do
    raise ArgumentError, "max_iterations must be non-negative, got: #{max}"
  end

  @doc """
  Creates a criterion that stops after a maximum runtime in seconds.

  This matches PyVRP's `MaxRuntime` which takes seconds as a float.

  Raises `ArgumentError` if max_runtime is negative.

  ## Example

      StoppingCriteria.max_runtime(60.0)  # 60 seconds

  """
  @spec max_runtime(number()) :: t()
  def max_runtime(max_seconds) when is_number(max_seconds) and max_seconds >= 0 do
    %__MODULE__{
      type: :max_runtime,
      state: %{max_ms: round(max_seconds * 1000), start_time: nil}
    }
  end

  def max_runtime(max_seconds) when is_number(max_seconds) do
    raise ArgumentError, "max_runtime must be non-negative, got: #{max_seconds}"
  end

  @doc """
  Creates a criterion that stops after N iterations without improvement.

  The counter resets whenever an improving solution is found, matching
  PyVRP's `NoImprovement` behavior.

  Raises `ArgumentError` if max_iterations is negative.

  ## Example

      StoppingCriteria.no_improvement(100)  # Stop after 100 iterations without improvement

  """
  @spec no_improvement(non_neg_integer()) :: t()
  def no_improvement(max_no_improvement) when is_integer(max_no_improvement) and max_no_improvement >= 0 do
    %__MODULE__{
      type: :no_improvement,
      state: %{max: max_no_improvement, current: 0}
    }
  end

  def no_improvement(max_no_improvement) when is_integer(max_no_improvement) do
    raise ArgumentError,
          "no_improvement max_iterations must be non-negative, got: #{max_no_improvement}"
  end

  @doc """
  Creates a combined criterion that stops when ANY of the sub-criteria are met.

  This matches PyVRP's `MultipleCriteria` class.

  Raises `ArgumentError` if the criteria list is empty.

  ## Example

      StoppingCriteria.multiple_criteria([
        StoppingCriteria.max_iterations(1000),
        StoppingCriteria.max_runtime(60.0)
      ])

  """
  @spec multiple_criteria([t()]) :: t()
  def multiple_criteria([]) do
    raise ArgumentError, "multiple_criteria requires at least one criterion"
  end

  def multiple_criteria(criteria) when is_list(criteria) do
    %__MODULE__{
      type: :multiple_criteria,
      state: %{criteria: criteria}
    }
  end

  @doc """
  Alias for `multiple_criteria/1` for convenience.
  """
  @spec any([t()]) :: t()
  def any(criteria), do: multiple_criteria(criteria)

  @doc """
  Creates a combined criterion that stops when ALL of the sub-criteria are met.

  Note: PyVRP's `MultipleCriteria` uses OR logic (any). This is an extension
  that uses AND logic (all must be met).
  """
  @spec all([t()]) :: t()
  def all([]) do
    raise ArgumentError, "all requires at least one criterion"
  end

  def all(criteria) when is_list(criteria) do
    %__MODULE__{
      type: :all,
      state: %{criteria: criteria}
    }
  end

  @doc """
  Creates a criterion that stops when a feasible solution is found.

  This matches PyVRP's `FirstFeasible` class.

  ## Example

      StoppingCriteria.first_feasible()

  """
  @spec first_feasible() :: t()
  def first_feasible do
    %__MODULE__{
      type: :first_feasible,
      state: %{}
    }
  end

  @doc """
  Creates a combined criterion that stops when EITHER a feasible solution
  is found OR the other criterion is met.

  This is useful for fleet minimisation where we want to stop early if we
  find a feasible solution, but also respect an overall stopping criterion.

  ## Example

      # Stop when feasible or after 1000 iterations, whichever comes first
      stop = StoppingCriteria.first_feasible_or(StoppingCriteria.max_iterations(1000))

  """
  @spec first_feasible_or(t()) :: t()
  def first_feasible_or(%__MODULE__{} = other_criteria) do
    multiple_criteria([first_feasible(), other_criteria])
  end

  @doc """
  Converts a StoppingCriteria struct to a stop function matching PyVRP's interface.

  The returned function takes `best_cost` and returns `true` to stop.
  Uses an Agent to maintain state across calls.

  ## Example

      criteria = StoppingCriteria.max_iterations(100)
      stop_fn = StoppingCriteria.to_stop_fn(criteria)
      stop_fn.(1000)  # => false (first call)
      # ... after 100 calls ...
      stop_fn.(1000)  # => true

  """
  @spec to_stop_fn(t()) :: stop_fn()
  def to_stop_fn(%__MODULE__{} = criteria) do
    {:ok, agent} = Agent.start_link(fn -> {criteria, nil, true} end)
    fn best_cost -> Agent.get_and_update(agent, &check_stop(&1, best_cost)) end
  end

  defp check_stop({crit, prev_cost, is_first_call}, best_cost) do
    crit = maybe_init_start_time(crit)
    # First call establishes baseline - not counted as "no improvement"
    # This matches PyVRP's behavior
    improved = is_first_call or best_cost < prev_cost
    context = %{improved: improved, best_cost: best_cost}
    {should_stop, new_crit} = should_stop?(crit, context)
    {should_stop, {new_crit, best_cost, false}}
  end

  # Initialize start_time on first call for max_runtime criteria
  defp maybe_init_start_time(%__MODULE__{type: :max_runtime, state: %{start_time: nil} = state} = criteria) do
    %{criteria | state: %{state | start_time: System.monotonic_time(:millisecond)}}
  end

  defp maybe_init_start_time(%__MODULE__{type: :multiple_criteria, state: state} = criteria) do
    updated_criteria = Enum.map(state.criteria, &maybe_init_start_time/1)
    %{criteria | state: %{state | criteria: updated_criteria}}
  end

  defp maybe_init_start_time(criteria), do: criteria

  @doc """
  Checks if the stopping criterion has been met.

  Returns `{should_stop?, updated_criteria}` where the updated criteria
  tracks any state changes (like iteration counts).
  """
  @spec should_stop?(t(), map()) :: {boolean(), t()}
  def should_stop?(%__MODULE__{type: :max_iterations, state: state} = criteria, _context) do
    new_current = state.current + 1
    should_stop = new_current >= state.max
    {should_stop, %{criteria | state: %{state | current: new_current}}}
  end

  def should_stop?(%__MODULE__{type: :max_runtime, state: state} = criteria, _context) do
    start_time = state.start_time || System.monotonic_time(:millisecond)
    elapsed = System.monotonic_time(:millisecond) - start_time
    should_stop = elapsed >= state.max_ms
    {should_stop, criteria}
  end

  def should_stop?(%__MODULE__{type: :no_improvement, state: state} = criteria, context) do
    improved = Map.get(context, :improved, false)

    new_current = if improved, do: 0, else: state.current + 1
    should_stop = new_current >= state.max

    {should_stop, %{criteria | state: %{state | current: new_current}}}
  end

  def should_stop?(%__MODULE__{type: :multiple_criteria, state: state} = criteria, context) do
    {results, _acc} =
      Enum.map_reduce(state.criteria, [], fn sub_criteria, acc ->
        {stop?, updated} = should_stop?(sub_criteria, context)
        {{stop?, updated}, acc ++ [updated]}
      end)

    any_stop = Enum.any?(results, fn {stop?, _} -> stop? end)
    final_criteria = Enum.map(results, fn {_, updated} -> updated end)

    {any_stop, %{criteria | state: %{criteria: final_criteria}}}
  end

  def should_stop?(%__MODULE__{type: :first_feasible} = criteria, context) do
    # In PyVRP, feasibility is determined by cost being finite
    # Our ILS passes :infinity for infeasible solutions (via solution_cost)
    best_cost = Map.get(context, :best_cost, :infinity)
    # :infinity is not an integer
    is_feasible = is_integer(best_cost)
    {is_feasible, criteria}
  end

  # Legacy support for :any and :all types
  def should_stop?(%__MODULE__{type: :any} = criteria, context) do
    should_stop?(%{criteria | type: :multiple_criteria}, context)
  end

  def should_stop?(%__MODULE__{type: :all, state: state} = criteria, context) do
    {results, _} =
      Enum.map_reduce(state.criteria, [], fn sub_criteria, acc ->
        {stop?, updated} = should_stop?(sub_criteria, context)
        {{stop?, updated}, acc ++ [updated]}
      end)

    all_stop = Enum.all?(results, fn {stop?, _} -> stop? end)
    final_criteria = Enum.map(results, fn {_, updated} -> updated end)

    {all_stop, %{criteria | state: %{criteria: final_criteria}}}
  end
end

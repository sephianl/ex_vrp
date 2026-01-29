defmodule ExVrp.IteratedLocalSearch do
  @moduledoc """
  Iterated Local Search with Late Acceptance Hill-Climbing.

  This is a direct port of PyVRP's IteratedLocalSearch. The algorithm:
  1. Starts with an initial solution
  2. Each iteration: applies local search to generate a candidate
  3. Accepts the candidate using Late Acceptance Hill-Climbing (LAHC)
  4. Restarts from best solution after N iterations without improvement
  5. Continues until stopping criterion is met

  Late Acceptance Hill-Climbing (Burke & Bykov, 2017) accepts moves based on
  comparison with historical solutions, not just the current solution. This
  allows temporary worsening moves to escape local optima.
  """

  alias ExVrp.Native
  alias ExVrp.PenaltyManager
  alias ExVrp.Solution

  defmodule Params do
    @moduledoc """
    Parameters for Iterated Local Search.
    """
    # These defaults match PyVRP's IteratedLocalSearchParams
    defstruct max_no_improvement: 50_000,
              # Number of iterations without improvement before restart
              # Size of the late acceptance history buffer
              history_size: 500

    @type t :: %__MODULE__{
            max_no_improvement: pos_integer(),
            history_size: pos_integer()
          }
  end

  # Ring buffer that matches PyVRP's RingBuffer behavior exactly
  # Key insight: skip() advances index without storing, keeping old element
  defmodule RingBuffer do
    @moduledoc false
    defstruct buffer: [], idx: 0, maxlen: 0

    def new(maxlen) do
      %__MODULE__{buffer: List.duplicate(nil, maxlen), idx: 0, maxlen: maxlen}
    end

    def clear(%__MODULE__{maxlen: maxlen}) do
      new(maxlen)
    end

    # Returns the element at current position (will be overwritten on append)
    def peek(%__MODULE__{buffer: buffer, idx: idx, maxlen: maxlen}) do
      Enum.at(buffer, rem(idx, maxlen))
    end

    # Append value at current position and advance index
    def append(%__MODULE__{buffer: buffer, idx: idx, maxlen: maxlen} = rb, value) do
      pos = rem(idx, maxlen)
      new_buffer = List.replace_at(buffer, pos, value)
      %{rb | buffer: new_buffer, idx: idx + 1}
    end

    # Advance index without storing (keeps old value)
    def skip(%__MODULE__{idx: idx} = rb) do
      %{rb | idx: idx + 1}
    end
  end

  defmodule Result do
    @moduledoc """
    Result of running ILS.

    This matches PyVRP's Result class interface:
    - `cost/1` - Returns the cost of the best solution (infinity if infeasible)
    - `feasible?/1` - Returns whether the best solution is feasible
    - `best` - The best Solution found
    - `stats` - Statistics from the search
    - `num_iterations` - Total iterations performed
    - `runtime` - Runtime in milliseconds
    """
    defstruct [:best, :stats, :num_iterations, :runtime]

    @type t :: %__MODULE__{
            best: Solution.t(),
            stats: map(),
            num_iterations: non_neg_integer(),
            runtime: non_neg_integer()
          }

    @doc """
    Returns the cost of the best solution.

    Returns `:infinity` if the solution is infeasible, matching PyVRP's behavior.
    """
    @spec cost(t()) :: non_neg_integer() | :infinity
    def cost(%__MODULE__{best: best}) do
      if best.is_feasible do
        best.distance
      else
        :infinity
      end
    end

    @doc """
    Returns whether the best solution is feasible.
    """
    @spec feasible?(t()) :: boolean()
    def feasible?(%__MODULE__{best: best}) do
      best.is_feasible
    end

    @doc """
    Returns a summary string of the result.
    """
    @spec summary(t()) :: String.t()
    def summary(%__MODULE__{} = result) do
      """
      Solution results
      ================
      Feasible: #{result.best.is_feasible}
      Cost: #{cost(result)}
      Routes: #{length(result.best.routes)}
      Clients: #{result.best.num_clients}
      Distance: #{result.best.distance}
      Duration: #{result.best.duration}
      Iterations: #{result.num_iterations}
      Runtime: #{result.runtime}ms
      """
    end
  end

  @type stop_fn :: (non_neg_integer() -> boolean())

  @doc """
  Runs the Iterated Local Search algorithm.

  ## Parameters

  - `problem_data` - Reference to the problem data
  - `penalty_manager` - PenaltyManager for dynamic penalty adjustment
  - `local_search` - Persistent LocalSearch resource from Native.create_local_search/1
  - `initial_solution` - Starting solution reference
  - `stop_fn` - Function that takes best_cost and returns true to stop
  - `params` - ILS parameters (optional)

  ## Returns

  A Result struct containing the best solution found and statistics.
  """
  @spec run(reference(), PenaltyManager.t(), reference(), reference(), stop_fn(), Params.t(), keyword()) :: Result.t()
  def run(problem_data, penalty_manager, local_search, initial_solution, stop_fn, params \\ %Params{}, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    # Get seed from options, default to random
    seed = Keyword.get(opts, :seed, :rand.uniform(1_000_000))

    # Get max_runtime_ms from options for per-iteration timeout calculation
    max_runtime_ms = Keyword.get(opts, :max_runtime_ms, nil)

    {:ok, cost_eval} = PenaltyManager.cost_evaluator(penalty_manager)

    initial_penalised_cost = Native.solution_penalised_cost(initial_solution, cost_eval)
    # For best selection and stopping criterion, use cost() which returns :infinity for infeasible
    # This matches PyVRP's behavior where infeasible solutions can never become "best"
    initial_cost = Native.solution_cost(initial_solution, cost_eval)

    state = %{
      problem_data: problem_data,
      penalty_manager: penalty_manager,
      local_search: local_search,
      cost_eval: cost_eval,
      params: params,
      best: initial_solution,
      # Use cost() for best selection - infeasible solutions have infinite cost
      best_cost: initial_cost,
      current: initial_solution,
      current_cost: initial_penalised_cost,
      # Ring buffer matching PyVRP's implementation exactly
      history: RingBuffer.new(params.history_size),
      iteration: 0,
      iters_no_improvement: 0,
      initial_cost: initial_penalised_cost,
      # Use seed for reproducible RNG in local search
      rng_seed: seed,
      start_time: start_time,
      max_runtime_ms: max_runtime_ms,
      stats: %{
        improvements: 0,
        restarts: 0
      }
    }

    final_state = iterate(state, stop_fn)

    runtime = System.monotonic_time(:millisecond) - start_time

    %Result{
      best: build_solution(final_state.best, problem_data, final_state),
      stats:
        Map.merge(final_state.stats, %{
          initial_cost: final_state.initial_cost,
          final_cost: final_state.best_cost
        }),
      num_iterations: final_state.iteration,
      runtime: runtime
    }
  end

  # Main iteration loop
  defp iterate(state, stop_fn) do
    # Log progress every 100 iterations
    if rem(state.iteration, 100) == 0 and state.iteration > 0 do
      require Logger

      Logger.info(
        "ILS iteration #{state.iteration}, best_cost=#{state.best_cost}, iters_no_improvement=#{state.iters_no_improvement}"
      )
    end

    # Use best_cost for stopping criterion - this is cost() which returns infinity
    # for infeasible solutions, matching PyVRP's behavior
    if stop_fn.(state.best_cost) do
      state
    else
      state
      |> maybe_restart()
      |> search_step()
      |> accept_step()
      |> update_penalty_manager()
      |> Map.update!(:iteration, &(&1 + 1))
      |> iterate(stop_fn)
    end
  end

  # Restart from best if no improvement for too long
  defp maybe_restart(%{iters_no_improvement: iters, params: params} = state) do
    if iters >= params.max_no_improvement do
      # On restart, recalculate current_cost as penalised_cost of best
      best_penalised = Native.solution_penalised_cost(state.best, state.cost_eval)

      %{
        state
        | current: state.best,
          current_cost: best_penalised,
          history: RingBuffer.clear(state.history),
          iters_no_improvement: 0,
          stats: Map.update!(state.stats, :restarts, &(&1 + 1))
      }
    else
      state
    end
  end

  # Apply local search to generate candidate
  defp search_step(state) do
    # Calculate remaining timeout for C++ local search (in milliseconds)
    timeout_ms =
      if state.max_runtime_ms do
        elapsed_ms = System.monotonic_time(:millisecond) - state.start_time
        # Pass remaining time, minimum 100ms to allow some work
        max(state.max_runtime_ms - elapsed_ms, 100)
      else
        # No timeout
        0
      end

    # Use persistent LocalSearch for performance
    # RNG is stored in the LocalSearch resource and advances across calls,
    # matching PyVRP's behavior
    {:ok, candidate} =
      Native.local_search_run(
        state.local_search,
        state.current,
        state.cost_eval,
        timeout_ms
      )

    candidate_cost = Native.solution_penalised_cost(candidate, state.cost_eval)

    Map.merge(state, %{
      candidate: candidate,
      candidate_cost: candidate_cost
    })
  end

  # Late Acceptance Hill-Climbing acceptance criterion
  # This matches PyVRP's implementation exactly:
  # - cost() for best selection (infeasible = infinity)
  # - penalised_cost() for LAHC acceptance
  defp accept_step(state) do
    %{
      candidate: candidate,
      candidate_cost: cand_cost,
      current: current,
      current_cost: curr_cost,
      best: best,
      best_cost: best_cost,
      history: history
    } = state

    # PyVRP line 146-149: Update best if candidate is new best (using cost())
    # iters_no_improvement is incremented unconditionally, then reset to 0 on improvement
    candidate_obj_cost = Native.solution_cost(candidate, state.cost_eval)
    iters_no_improvement = state.iters_no_improvement + 1

    {new_best, new_best_cost, new_iters_no_improvement, new_stats} =
      if candidate_obj_cost < best_cost do
        {candidate, candidate_obj_cost, 0, Map.update!(state.stats, :improvements, &(&1 + 1))}
      else
        {best, best_cost, iters_no_improvement, state.stats}
      end

    # PyVRP lines 157-159: late_cost from history.peek() or best
    late = RingBuffer.peek(history)

    late_cost =
      if late == nil do
        Native.solution_penalised_cost(new_best, state.cost_eval)
      else
        Native.solution_penalised_cost(late, state.cost_eval)
      end

    # PyVRP line 165: Accept if better than late or current
    accept? = cand_cost < late_cost or cand_cost < curr_cost

    # Update current if accepted
    {new_current, new_curr_cost} =
      if accept? do
        {candidate, cand_cost}
      else
        {current, curr_cost}
      end

    # PyVRP lines 171-174: Update history
    # - append(current) if curr_cost < late_cost OR late is nil
    # - skip() otherwise
    new_history =
      if new_curr_cost < late_cost or late == nil do
        RingBuffer.append(history, new_current)
      else
        RingBuffer.skip(history)
      end

    %{
      state
      | current: new_current,
        current_cost: new_curr_cost,
        best: new_best,
        best_cost: new_best_cost,
        history: new_history,
        iters_no_improvement: new_iters_no_improvement,
        stats: new_stats
    }
  end

  # Update penalty manager with candidate solution
  defp update_penalty_manager(state) do
    new_pm = PenaltyManager.register(state.penalty_manager, state.candidate)

    # If penalties changed, update cost evaluator
    if new_pm == state.penalty_manager do
      state
    else
      {:ok, new_cost_eval} = PenaltyManager.cost_evaluator(new_pm)
      %{state | penalty_manager: new_pm, cost_eval: new_cost_eval}
    end
  end

  # Build Solution struct from solution reference
  defp build_solution(solution_ref, problem_data, state) do
    %Solution{
      routes: Native.solution_routes(solution_ref),
      solution_ref: solution_ref,
      problem_data: problem_data,
      distance: Native.solution_distance(solution_ref),
      duration: Native.solution_duration(solution_ref),
      num_clients: Native.solution_num_clients(solution_ref),
      is_feasible: Native.solution_is_feasible(solution_ref),
      is_complete: Native.solution_is_complete(solution_ref),
      stats: %{
        iterations: state.iteration,
        initial_cost: state.initial_cost,
        final_cost: state.best_cost,
        improvements: state.stats.improvements,
        restarts: state.stats.restarts
      }
    }
  end
end

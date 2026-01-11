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
    defstruct max_no_improvement: 5000,
              # Number of iterations without improvement before restart
              # Size of the late acceptance history buffer
              history_size: 50

    @type t :: %__MODULE__{
            max_no_improvement: pos_integer(),
            history_size: pos_integer()
          }
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
  - `initial_solution` - Starting solution reference
  - `stop_fn` - Function that takes best_cost and returns true to stop
  - `params` - ILS parameters (optional)

  ## Returns

  A Result struct containing the best solution found and statistics.
  """
  @spec run(reference(), PenaltyManager.t(), reference(), stop_fn(), Params.t()) :: Result.t()
  def run(problem_data, penalty_manager, initial_solution, stop_fn, params \\ %Params{}) do
    start_time = System.monotonic_time(:millisecond)

    {:ok, cost_eval} = PenaltyManager.cost_evaluator(penalty_manager)

    initial_penalised_cost = Native.solution_penalised_cost(initial_solution, cost_eval)
    # For stopping criterion, use cost() which returns :infinity for infeasible
    initial_stop_cost = Native.solution_cost(initial_solution, cost_eval)

    state = %{
      problem_data: problem_data,
      penalty_manager: penalty_manager,
      cost_eval: cost_eval,
      params: params,
      best: initial_solution,
      best_cost: initial_penalised_cost,
      # For stopping criterion (infinity if infeasible)
      best_stop_cost: initial_stop_cost,
      current: initial_solution,
      current_cost: initial_penalised_cost,
      history: :queue.new(),
      history_size: 0,
      iteration: 0,
      iters_no_improvement: 0,
      initial_cost: initial_penalised_cost,
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
    # Use best_stop_cost for stopping criterion - this is :infinity for infeasible
    # solutions, matching PyVRP's behavior where cost() returns INT_MAX for infeasible
    if stop_fn.(state.best_stop_cost) do
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
      %{
        state
        | current: state.best,
          current_cost: state.best_cost,
          history: :queue.new(),
          history_size: 0,
          iters_no_improvement: 0,
          stats: Map.update!(state.stats, :restarts, &(&1 + 1))
      }
    else
      state
    end
  end

  # Apply local search to generate candidate
  defp search_step(state) do
    {:ok, candidate} =
      Native.local_search(
        state.current,
        state.problem_data,
        state.cost_eval,
        exhaustive: false
      )

    candidate_cost = Native.solution_penalised_cost(candidate, state.cost_eval)

    Map.merge(state, %{
      candidate: candidate,
      candidate_cost: candidate_cost
    })
  end

  # Late Acceptance Hill-Climbing acceptance criterion
  defp accept_step(state) do
    %{
      candidate: candidate,
      candidate_cost: candidate_cost,
      current_cost: current_cost,
      best_cost: best_cost,
      history: history,
      history_size: history_size,
      params: params
    } = state

    # Get historical cost for comparison (or use best if history is empty)
    hist_cost =
      if history_size > 0 do
        {:value, {cost, _}} = :queue.peek(history)
        cost
      else
        best_cost
      end

    # Accept if candidate is better than historical or current
    accept? = candidate_cost < hist_cost or candidate_cost < current_cost

    if accept? do
      # Update best if this is a new best
      {new_best, new_best_cost, new_best_stop_cost, new_iters_no_improvement, new_stats} =
        if candidate_cost < best_cost do
          # Also compute the stop cost for the new best (infinity if infeasible)
          candidate_stop_cost = Native.solution_cost(candidate, state.cost_eval)
          {candidate, candidate_cost, candidate_stop_cost, 0, Map.update!(state.stats, :improvements, &(&1 + 1))}
        else
          {state.best, best_cost, state.best_stop_cost, state.iters_no_improvement + 1, state.stats}
        end

      # Update history only when candidate improves over historical
      {new_history, new_history_size} =
        if candidate_cost < hist_cost do
          add_to_history(history, history_size, current_cost, state.current, params.history_size)
        else
          {history, history_size}
        end

      %{
        state
        | current: candidate,
          current_cost: candidate_cost,
          best: new_best,
          best_cost: new_best_cost,
          best_stop_cost: new_best_stop_cost,
          history: new_history,
          history_size: new_history_size,
          iters_no_improvement: new_iters_no_improvement,
          stats: new_stats
      }
    else
      %{state | iters_no_improvement: state.iters_no_improvement + 1}
    end
  end

  # Add to ring buffer history
  defp add_to_history(history, size, cost, solution, max_size) do
    if size >= max_size do
      # Remove oldest, add new
      {_, new_history} = :queue.out(history)
      {:queue.in({cost, solution}, new_history), max_size}
    else
      {:queue.in({cost, solution}, history), size + 1}
    end
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

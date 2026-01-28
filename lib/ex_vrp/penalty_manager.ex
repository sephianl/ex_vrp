defmodule ExVrp.PenaltyManager do
  @moduledoc """
  Manages and dynamically adjusts penalty weights for constraint violations.

  This is a direct port of PyVRP's PenaltyManager. It tracks the feasibility
  of registered solutions and adjusts penalties to target a specific feasibility
  rate (default 65%). This balances exploration between feasible and infeasible
  solution space.
  """

  alias ExVrp.Native

  defmodule Params do
    @moduledoc """
    Parameters for penalty management.
    """
    defstruct solutions_between_updates: 500,
              penalty_increase: 1.25,
              penalty_decrease: 0.85,
              target_feasible: 0.65,
              feas_tolerance: 0.05,
              min_penalty: 0.1,
              max_penalty: 100_000.0

    @type t :: %__MODULE__{
            solutions_between_updates: pos_integer(),
            penalty_increase: float(),
            penalty_decrease: float(),
            target_feasible: float(),
            feas_tolerance: float(),
            min_penalty: float(),
            max_penalty: float()
          }
  end

  @type t :: %__MODULE__{
          load_penalties: [float()],
          tw_penalty: float(),
          dist_penalty: float(),
          params: Params.t(),
          load_feas: [[boolean()]],
          tw_feas: [boolean()],
          dist_feas: [boolean()]
        }

  defstruct [
    :load_penalties,
    :tw_penalty,
    :dist_penalty,
    :params,
    load_feas: [],
    tw_feas: [],
    dist_feas: []
  ]

  @doc """
  Creates a new PenaltyManager with explicit initial penalties.
  """
  @spec new([float()], float(), float(), Params.t()) :: t()
  def new(load_penalties, tw_penalty, dist_penalty, params \\ %Params{}) do
    %__MODULE__{
      load_penalties: clip_penalties(load_penalties, params),
      tw_penalty: clip_penalty(tw_penalty, params),
      dist_penalty: clip_penalty(dist_penalty, params),
      params: params,
      load_feas: Enum.map(load_penalties, fn _ -> [] end),
      tw_feas: [],
      dist_feas: []
    }
  end

  @doc """
  Creates a PenaltyManager with initial penalties computed from problem data.

  This mirrors PyVRP's `PenaltyManager.init_from()` - it computes reasonable
  initial penalty values based on the problem's cost structure.
  """
  @spec init_from(reference(), Params.t()) :: t()
  def init_from(problem_data, params \\ %Params{}) do
    num_dims = Native.problem_data_num_load_dims(problem_data)
    num_locs = Native.problem_data_num_locations(problem_data)

    edge_costs = compute_min_edge_costs(problem_data)
    min_distances = compute_min_matrix(problem_data, &Native.problem_data_distance_matrix_nif/2)
    min_durations = compute_min_matrix(problem_data, &Native.problem_data_duration_matrix_nif/2)

    avg_cost = matrix_avg(edge_costs, num_locs)
    avg_distance = matrix_avg(min_distances, num_locs)
    avg_duration = matrix_avg(min_durations, num_locs)

    # For load penalty, use max_penalty since we don't have easy access to
    # pickup/delivery data here. The penalty manager will adapt during search.
    init_load = List.duplicate(params.max_penalty, num_dims)
    init_tw = avg_cost / max(avg_duration, 1.0)
    init_dist = avg_cost / max(avg_distance, 1.0)

    # For prize-collecting problems, ensure tw_penalty is high enough relative
    # to prizes. Otherwise the solver may prefer keeping clients with time warp
    # violations over removing them.
    # We want: tw_penalty * typical_time_warp > avg_prize
    # Assuming typical time warp is ~1 hour (3600s), we need:
    # tw_penalty > avg_prize / 3600
    clients = Native.problem_data_clients_nif(problem_data)
    prizes = Enum.map(clients, fn {_, _, _, prize} -> prize end)
    max_prize = if Enum.empty?(prizes), do: 0, else: Enum.max(prizes)

    init_tw =
      if max_prize > 0 do
        # Set tw_penalty so that even small time warps are heavily penalized.
        # We want 1 minute (60s) of time warp to cost as much as one prize.
        # This strongly discourages any time warp violations.
        prize_based_tw = max_prize / 60.0
        max(init_tw, prize_based_tw)
      else
        init_tw
      end

    new(init_load, init_tw, init_dist, params)
  end

  defp compute_min_edge_costs(problem_data) do
    problem_data
    |> Native.problem_data_vehicle_types_nif()
    |> Enum.uniq()
    |> Enum.map(fn {unit_dist, unit_dur, profile} ->
      compute_edge_cost_matrix(problem_data, profile, unit_dist, unit_dur)
    end)
    |> elementwise_min_matrices()
  end

  defp compute_edge_cost_matrix(problem_data, profile, unit_dist, unit_dur) do
    dist_mat = Native.problem_data_distance_matrix_nif(problem_data, profile)
    dur_mat = Native.problem_data_duration_matrix_nif(problem_data, profile)

    Enum.zip_with(dist_mat, dur_mat, fn row_dist, row_dur ->
      Enum.zip_with(row_dist, row_dur, fn d, t ->
        unit_dist * d + unit_dur * t
      end)
    end)
  end

  defp compute_min_matrix(problem_data, matrix_fn) do
    num_profiles = Native.problem_data_num_profiles_nif(problem_data)

    0..(num_profiles - 1)
    |> Enum.map(&matrix_fn.(problem_data, &1))
    |> elementwise_min_matrices()
  end

  defp elementwise_min_matrices([single]), do: single

  defp elementwise_min_matrices([first | rest]) do
    Enum.reduce(rest, first, &elementwise_min/2)
  end

  defp elementwise_min(mat_a, mat_b) do
    Enum.zip_with(mat_a, mat_b, fn row_a, row_b ->
      Enum.zip_with(row_a, row_b, &min/2)
    end)
  end

  defp matrix_avg(matrix, num_locs) do
    matrix_sum(matrix) / (num_locs * num_locs)
  end

  defp matrix_sum(matrix) do
    Enum.reduce(matrix, 0, fn row, acc ->
      acc + Enum.sum(row)
    end)
  end

  @doc """
  Returns the current penalties as a tuple.
  """
  @spec penalties(t()) :: {[float()], float(), float()}
  def penalties(%__MODULE__{} = pm) do
    {pm.load_penalties, pm.tw_penalty, pm.dist_penalty}
  end

  @doc """
  Creates a CostEvaluator using the current penalty values.
  """
  @spec cost_evaluator(t()) :: {:ok, reference()} | {:error, term()}
  def cost_evaluator(%__MODULE__{} = pm) do
    Native.create_cost_evaluator(
      load_penalties: pm.load_penalties,
      tw_penalty: pm.tw_penalty,
      dist_penalty: pm.dist_penalty
    )
  end

  @doc """
  Creates a CostEvaluator using maximum penalty values.
  Used for final solution evaluation.
  """
  @spec max_cost_evaluator(t()) :: {:ok, reference()} | {:error, term()}
  def max_cost_evaluator(%__MODULE__{params: params} = pm) do
    Native.create_cost_evaluator(
      load_penalties: Enum.map(pm.load_penalties, fn _ -> params.max_penalty end),
      tw_penalty: params.max_penalty,
      dist_penalty: params.max_penalty
    )
  end

  @doc """
  Registers a solution and updates penalties if needed.

  Tracks the feasibility of the solution across load, time window, and distance
  dimensions. After `solutions_between_updates` registrations, penalties are
  adjusted to target the configured feasibility rate.
  """
  @spec register(t(), reference()) :: t()
  def register(%__MODULE__{} = pm, solution_ref) do
    # Get feasibility info from solution
    is_feasible = Native.solution_is_feasible(solution_ref)

    # For now, treat all dimensions the same based on overall feasibility
    # A more accurate implementation would check each dimension separately
    pm
    |> register_load_feasibility(is_feasible)
    |> register_tw_feasibility(is_feasible)
    |> register_dist_feasibility(is_feasible)
    |> maybe_update_penalties()
  end

  # Private functions

  defp register_load_feasibility(%__MODULE__{load_feas: load_feas} = pm, is_feasible) do
    # Add feasibility to each dimension's list
    new_load_feas = Enum.map(load_feas, fn dim_feas -> [is_feasible | dim_feas] end)
    %{pm | load_feas: new_load_feas}
  end

  defp register_tw_feasibility(%__MODULE__{tw_feas: tw_feas} = pm, is_feasible) do
    %{pm | tw_feas: [is_feasible | tw_feas]}
  end

  defp register_dist_feasibility(%__MODULE__{dist_feas: dist_feas} = pm, is_feasible) do
    %{pm | dist_feas: [is_feasible | dist_feas]}
  end

  defp maybe_update_penalties(%__MODULE__{params: params, tw_feas: tw_feas} = pm) do
    if length(tw_feas) >= params.solutions_between_updates do
      update_penalties(pm)
    else
      pm
    end
  end

  defp update_penalties(%__MODULE__{params: params} = pm) do
    # Update load penalties for each dimension
    new_load_penalties =
      pm.load_penalties
      |> Enum.zip(pm.load_feas)
      |> Enum.map(fn {penalty, feas_list} ->
        compute_new_penalty(penalty, feas_list, params)
      end)

    # Update time window penalty
    new_tw_penalty = compute_new_penalty(pm.tw_penalty, pm.tw_feas, params)

    # Update distance penalty
    new_dist_penalty = compute_new_penalty(pm.dist_penalty, pm.dist_feas, params)

    # Reset feasibility tracking
    %{
      pm
      | load_penalties: new_load_penalties,
        tw_penalty: new_tw_penalty,
        dist_penalty: new_dist_penalty,
        load_feas: Enum.map(pm.load_feas, fn _ -> [] end),
        tw_feas: [],
        dist_feas: []
    }
  end

  defp compute_new_penalty(current_penalty, feas_list, params) do
    if Enum.empty?(feas_list) do
      current_penalty
    else
      feas_count = Enum.count(feas_list, & &1)
      feas_rate = feas_count / length(feas_list)

      new_penalty =
        cond do
          feas_rate < params.target_feasible - params.feas_tolerance ->
            # Too few feasible - increase penalty
            current_penalty * params.penalty_increase

          feas_rate > params.target_feasible + params.feas_tolerance ->
            # Too many feasible - decrease penalty
            current_penalty * params.penalty_decrease

          true ->
            # Within tolerance - no change
            current_penalty
        end

      clip_penalty(new_penalty, params)
    end
  end

  defp clip_penalties(penalties, params) do
    Enum.map(penalties, &clip_penalty(&1, params))
  end

  defp clip_penalty(penalty, params) do
    penalty
    |> max(params.min_penalty)
    |> min(params.max_penalty)
  end
end

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
    num_profiles = Native.problem_data_num_profiles_nif(problem_data)
    num_locs = Native.problem_data_num_locations(problem_data)

    # Get vehicle type info for edge cost computation
    vehicle_types = Native.problem_data_vehicle_types_nif(problem_data)

    # Collect unique (unit_dist, unit_dur, profile) combinations
    # vehicle_types_nif returns list of {unit_distance_cost, unit_duration_cost, profile} tuples
    unique_edge_costs = Enum.uniq(vehicle_types)

    # Compute minimum edge costs across all vehicle types
    # Initialize with first vehicle type
    [{first_dist, first_dur, first_prof} | rest] = unique_edge_costs
    dist_mat = Native.problem_data_distance_matrix_nif(problem_data, first_prof)
    dur_mat = Native.problem_data_duration_matrix_nif(problem_data, first_prof)

    # Compute initial edge costs
    initial_costs =
      for i <- 0..(num_locs - 1) do
        row_dist = Enum.at(dist_mat, i)
        row_dur = Enum.at(dur_mat, i)

        for j <- 0..(num_locs - 1) do
          first_dist * Enum.at(row_dist, j) + first_dur * Enum.at(row_dur, j)
        end
      end

    # Take elementwise minimum across remaining vehicle types
    edge_costs =
      Enum.reduce(rest, initial_costs, fn {unit_dist, unit_dur, profile}, acc ->
        dist_mat = Native.problem_data_distance_matrix_nif(problem_data, profile)
        dur_mat = Native.problem_data_duration_matrix_nif(problem_data, profile)

        for {row_acc, i} <- Enum.with_index(acc) do
          row_dist = Enum.at(dist_mat, i)
          row_dur = Enum.at(dur_mat, i)

          for {val_acc, j} <- Enum.with_index(row_acc) do
            cost = unit_dist * Enum.at(row_dist, j) + unit_dur * Enum.at(row_dur, j)
            min(val_acc, cost)
          end
        end
      end)

    # Compute minimum distance/duration matrices across all profiles
    min_distances =
      Enum.reduce(0..(num_profiles - 1), nil, fn p, acc ->
        mat = Native.problem_data_distance_matrix_nif(problem_data, p)

        if acc == nil do
          mat
        else
          for {row_acc, row_mat} <- Enum.zip(acc, mat) do
            for {val_acc, val_mat} <- Enum.zip(row_acc, row_mat) do
              min(val_acc, val_mat)
            end
          end
        end
      end)

    min_durations =
      Enum.reduce(0..(num_profiles - 1), nil, fn p, acc ->
        mat = Native.problem_data_duration_matrix_nif(problem_data, p)

        if acc == nil do
          mat
        else
          for {row_acc, row_mat} <- Enum.zip(acc, mat) do
            for {val_acc, val_mat} <- Enum.zip(row_acc, row_mat) do
              min(val_acc, val_mat)
            end
          end
        end
      end)

    # Compute averages (sum / count)
    total_entries = num_locs * num_locs
    avg_cost = matrix_sum(edge_costs) / total_entries
    avg_distance = matrix_sum(min_distances) / total_entries
    avg_duration = matrix_sum(min_durations) / total_entries

    # For load penalty, use max_penalty since we don't have easy access to
    # pickup/delivery data here. PyVRP does the same for instances where
    # avg_load computes to a very small value.
    # The penalty manager will adapt these values during search anyway.
    init_load = List.duplicate(params.max_penalty, num_dims)

    init_tw = avg_cost / max(avg_duration, 1.0)
    init_dist = avg_cost / max(avg_distance, 1.0)

    new(init_load, init_tw, init_dist, params)
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

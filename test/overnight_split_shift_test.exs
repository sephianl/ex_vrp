defmodule ExVrp.OvernightSplitShiftTest do
  @moduledoc """
  Tests for overnight routes with split driver shifts and multi-trip.

  Models a real-world scenario: a driver works two shifts (e.g., 20:00-23:59
  and 00:00-03:00) with a short gap at midnight. The solver must split
  deliveries into two trips via depot reload, respecting the forbidden window
  between shifts.

  Uses Zelo-like parameters:
  - 900s depot reload time (450s load + 450s unload)
  - 4 optional clients with prize-collecting (100_000 prize each)
  - Clients have time windows matching the shift they belong to
  - 60s forbidden window between shifts (23:59-00:00)
  - Vehicle fixed cost 93_000, reload cost 93_900
  - Only 100 iterations (matches Zelo dev/test mode)

  Must be feasible across ALL seeds — this is a trivial 4-client problem.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solution
  alias ExVrp.Solver

  @client_prize 100_000
  @vehicle_fixed_cost 93_000

  # After load/unload padding (450s each):
  # Shift 1: 450 to 13890 (original 0-14340 padded by load_s/unload_s)
  # Shift 2: 14850 to 24750 (original 14400-25200 padded)
  # Forbidden: 13890 to 14850 (960s gap including padding)
  @shift1_start 450
  @shift1_end 13_890
  @shift2_start 14_850
  @shift2_end 24_750
  @depot_reload_time 900

  defp overnight_split_shift_model do
    # 5x5 matrix: 1 depot + 4 clients
    # Travel times ~120s between locations (bicycle-like, close to depot)
    duration_matrix = [
      [0, 120, 150, 130, 140],
      [120, 0, 100, 110, 120],
      [150, 100, 0, 90, 100],
      [130, 110, 90, 0, 80],
      [140, 120, 100, 80, 0]
    ]

    Model.new()
    |> Model.add_depot(
      x: 0,
      y: 0,
      tw_early: 0,
      tw_late: @shift2_end,
      service_duration: @depot_reload_time,
      reload_cost: @depot_reload_time + @vehicle_fixed_cost
    )
    # Clients 0,1: shift 1 (20:00-23:59 → solver seconds 0-14340)
    |> Model.add_client(
      x: 1,
      y: 0,
      delivery: [10],
      tw_early: 0,
      tw_late: 14_340,
      service_duration: 120,
      required: false,
      prize: @client_prize
    )
    |> Model.add_client(
      x: 2,
      y: 0,
      delivery: [10],
      tw_early: 0,
      tw_late: 14_340,
      service_duration: 120,
      required: false,
      prize: @client_prize
    )
    # Clients 2,3: shift 2 (00:00-03:00 → solver seconds 14400-25200)
    |> Model.add_client(
      x: 3,
      y: 0,
      delivery: [10],
      tw_early: 14_400,
      tw_late: 25_200,
      service_duration: 120,
      required: false,
      prize: @client_prize
    )
    |> Model.add_client(
      x: 4,
      y: 0,
      delivery: [10],
      tw_early: 14_400,
      tw_late: 25_200,
      service_duration: 120,
      required: false,
      prize: @client_prize
    )
    |> Model.add_vehicle_type(
      num_available: 1,
      capacity: [100],
      time_windows: [{@shift1_start, @shift1_end}, {@shift2_start, @shift2_end}],
      reload_depots: [0],
      max_reloads: :infinity,
      unit_duration_cost: 1,
      fixed_cost: @vehicle_fixed_cost
    )
    |> Model.set_duration_matrices([duration_matrix])
    |> Model.set_distance_matrices([duration_matrix])
  end

  describe "overnight split shift feasibility (100 iterations)" do
    for seed <- [1, 7, 13, 42, 99, 123, 256, 500, 777, 999] do
      test "feasible with seed #{seed} at 100 iterations" do
        {:ok, result} =
          Solver.solve(
            overnight_split_shift_model(),
            max_iterations: 100,
            seed: unquote(seed)
          )

        solution = result.best
        assert Solution.feasible?(solution), "Infeasible with seed #{unquote(seed)}"

        assert Solution.num_clients(solution) == 4,
               "Expected all 4 clients, got #{Solution.num_clients(solution)} with seed #{unquote(seed)}"
      end
    end
  end

  describe "overnight split shift schedule correctness" do
    test "no service during forbidden window" do
      {:ok, result} = Solver.solve(overnight_split_shift_model(), max_iterations: 500, seed: 42)
      assert Solution.feasible?(result.best)

      schedule = Solution.route_schedule(result.best, 0)

      for visit <- schedule do
        refute visit.start_service >= @shift1_end and visit.start_service < @shift2_start,
               "Visit at location #{visit.location} starts at #{visit.start_service} during forbidden window [#{@shift1_end}, #{@shift2_start})"
      end
    end

    test "shift 1 clients served before forbidden window" do
      {:ok, result} = Solver.solve(overnight_split_shift_model(), max_iterations: 500, seed: 42)
      schedule = Solution.route_schedule(result.best, 0)

      shift1_visits = Enum.filter(schedule, &(&1.location in [1, 2]))

      for visit <- shift1_visits do
        assert visit.end_service <= 14_340,
               "Shift 1 client at location #{visit.location} ends at #{visit.end_service}, should end by 14340"
      end
    end

    test "shift 2 clients served after forbidden window" do
      {:ok, result} = Solver.solve(overnight_split_shift_model(), max_iterations: 500, seed: 42)
      schedule = Solution.route_schedule(result.best, 0)

      shift2_visits = Enum.filter(schedule, &(&1.location in [3, 4]))

      for visit <- shift2_visits do
        assert visit.start_service >= 14_400,
               "Shift 2 client at location #{visit.location} starts at #{visit.start_service}, should start at or after 14400"
      end
    end
  end
end

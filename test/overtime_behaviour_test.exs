defmodule ExVrp.OvertimeBehaviourTest do
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  @matrix [
    [0, 100, 100],
    [100, 0, 100],
    [100, 100, 0]
  ]

  @shift_duration 250
  @max_overtime 100

  defp build_model(unit_overtime_cost) do
    Model.new()
    |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 10_000)
    |> Model.add_client(x: 1, y: 0, delivery: [1], tw_early: 0, tw_late: 10_000)
    |> Model.add_client(x: 2, y: 0, delivery: [1], tw_early: 0, tw_late: 10_000)
    |> Model.add_vehicle_type(
      num_available: 2,
      capacity: [2],
      fixed_cost: 50,
      unit_distance_cost: 1,
      unit_duration_cost: 0,
      shift_duration: @shift_duration,
      max_duration: @shift_duration + @max_overtime,
      unit_overtime_cost: unit_overtime_cost,
      time_windows: [{0, 10_000}]
    )
    |> Model.set_distance_matrices([@matrix])
    |> Model.set_duration_matrices([@matrix])
  end

  defp solve(unit_overtime_cost) do
    {:ok, %{best: best}} =
      ExVrp.solve(build_model(unit_overtime_cost),
        stop: StoppingCriteria.max_iterations(2_000),
        seed: 42,
        num_starts: 1
      )

    best
  end

  test "cheap overtime is spent to keep the work on one vehicle" do
    best = solve(0)

    assert length(Solution.routes(best)) == 1
    assert Solution.overtime(best) == 50
  end

  test "expensive overtime opens a second vehicle instead" do
    best = solve(10)

    assert length(Solution.routes(best)) == 2
    assert Solution.overtime(best) == 0
  end

  test "max_duration is never exceeded" do
    best = solve(0)

    Enum.each(Solution.routes(best), fn route ->
      assert Route.duration(route) <= @shift_duration + @max_overtime
    end)
  end

  describe "a widened window is not the same thing as overtime" do
    @late_matrix [
      [0, 50],
      [50, 0]
    ]

    @late_nominal 200

    defp solve_late_client(tw_late, max_overtime, overtime_start \\ :infinity) do
      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 10_000)
        |> Model.add_client(x: 1, y: 0, delivery: [1], tw_early: 500, tw_late: 600, prize: 100_000)
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [5],
          fixed_cost: 0,
          unit_distance_cost: 1,
          unit_duration_cost: 1,
          shift_duration: @late_nominal,
          max_duration: @late_nominal + max_overtime,
          unit_overtime_cost: 1,
          overtime_start: overtime_start,
          time_windows: [{0, tw_late}]
        )
        |> Model.set_distance_matrices([@late_matrix])
        |> Model.set_duration_matrices([@late_matrix])

      {:ok, %{best: best}} =
        ExVrp.solve(model, stop: StoppingCriteria.max_iterations(2_000), seed: 42, num_starts: 1)

      best
    end

    test "a client past the window end cannot be served feasibly without an allowance" do
      best = solve_late_client(300, 0)

      refute Solution.feasible?(best)
    end

    test "extending the window serves that client for zero overtime, by starting later" do
      best = solve_late_client(700, 400)

      [route] = Solution.routes(best)

      assert Solution.feasible?(best)
      assert Route.visits(route) == [1]
      assert Route.duration(route) == 100
      assert Solution.overtime(best) == 0
    end
  end

  describe "clock-based overtime via overtime_start" do
    test "every second past the contracted end is overtime, however short the route" do
      best = solve_late_client(700, 400, 300)

      [route] = Solution.routes(best)

      assert Solution.feasible?(best)
      assert Route.end_time(route) == 550
      assert Route.duration(route) == 100
      assert Solution.overtime(best) == 250
    end

    test "a route finishing on the contracted end incurs no overtime" do
      best = solve_late_client(700, 400, 550)

      assert Solution.feasible?(best)
      assert Solution.overtime(best) == 0
    end
  end

  describe "search and final routes agree on clock-based overtime" do
    defp forbidden_window_model(time_windows) do
      Model.new()
      |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 10_000)
      |> Model.add_client(x: 1, y: 0, delivery: [1], tw_early: 0, tw_late: 10_000)
      |> Model.add_client(x: 2, y: 0, delivery: [1], tw_early: 0, tw_late: 10_000)
      |> Model.add_vehicle_type(
        num_available: 1,
        capacity: [10],
        unit_distance_cost: 1,
        unit_duration_cost: 0,
        shift_duration: 10_000,
        max_duration: :infinity,
        overtime_start: 250,
        unit_overtime_cost: 1,
        time_windows: time_windows
      )
      |> Model.set_distance_matrices([@matrix])
      |> Model.set_duration_matrices([@matrix])
    end

    defp search_overtime(model) do
      {:ok, problem_data} = Model.to_problem_data(model)
      route = Native.create_search_route_nif(problem_data, 0, 0)

      Native.search_route_insert_nif(route, 1, Native.create_search_node_nif(problem_data, 1))
      Native.search_route_insert_nif(route, 2, Native.create_search_node_nif(problem_data, 2))
      Native.search_route_update_nif(route)

      Native.search_route_overtime_nif(route)
    end

    defp final_overtime(model) do
      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, solution} = Native.create_solution_from_routes_with_types(problem_data, [{0, [1, 2]}])

      Native.solution_route_overtime(solution, 0)
    end

    test "without a forbidden window" do
      model = forbidden_window_model([{0, 10_000}])

      assert search_overtime(model) == 50
      assert final_overtime(model) == 50
    end

    test "with a forbidden window the vehicle must idle through" do
      model = forbidden_window_model([{0, 150}, {400, 10_000}])

      assert search_overtime(model) == 250
      assert final_overtime(model) == 250
    end
  end
end

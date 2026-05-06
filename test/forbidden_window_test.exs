defmodule ExVrp.ForbiddenWindowTest do
  @moduledoc """
  Tests for forbidden time window handling in the solver.

  Forbidden windows are periods during which a vehicle must be idle at the
  depot. They arise from gaps between time_windows in the VehicleType config.
  The solver must:
  - Not schedule service during forbidden windows
  - Use multi-trip to split work across allowed windows
  - Avoid oscillation when removing/inserting optional clients
  - Correctly account for forbidden delays in cost evaluation
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  defp assert_no_service_in_forbidden_windows(schedule, forbidden_windows) do
    for visit <- schedule do
      for {fw_start, fw_end} <- forbidden_windows do
        refute visit.start_service >= fw_start and visit.start_service < fw_end,
               "Visit at #{visit.start_service} falls in forbidden window [#{fw_start}, #{fw_end})"
      end
    end
  end

  describe "basic forbidden window feasibility" do
    test "single client served before forbidden window" do
      duration_matrix = [
        [0, 10],
        [10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000)
        |> Model.add_client(
          x: 10,
          y: 0,
          delivery: [10],
          tw_early: 0,
          tw_late: 400,
          service_duration: 50
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 500}, {700, 1000}]
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 500, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.complete?(solution)

      schedule = Solution.route_schedule(solution, 0)
      assert_no_service_in_forbidden_windows(schedule, [{500, 700}])
    end

    test "clients split across two time windows with multi-trip" do
      duration_matrix = [
        [0, 5, 5],
        [5, 0, 10],
        [5, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 2000, service_duration: 10)
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [50],
          tw_early: 0,
          tw_late: 400,
          service_duration: 50,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [50],
          tw_early: 700,
          tw_late: 1500,
          service_duration: 50,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 500}, {700, 2000}],
          reload_depots: [0],
          max_reloads: 5
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 1000, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.num_clients(solution) == 2

      schedule = Solution.route_schedule(solution, 0)
      assert_no_service_in_forbidden_windows(schedule, [{500, 700}])
    end

    test "no service during any forbidden window with three time windows" do
      duration_matrix = [
        [0, 5, 5, 5],
        [5, 0, 10, 10],
        [5, 10, 0, 10],
        [5, 10, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 3000, service_duration: 10)
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [30],
          tw_early: 0,
          tw_late: 300,
          service_duration: 30,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [30],
          tw_early: 600,
          tw_late: 900,
          service_duration: 30,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [30],
          tw_early: 1200,
          tw_late: 1500,
          service_duration: 30,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 400}, {600, 1000}, {1200, 1600}],
          reload_depots: [0],
          max_reloads: 5
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 2000, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.num_clients(solution) == 3

      schedule = Solution.route_schedule(solution, 0)
      assert_no_service_in_forbidden_windows(schedule, [{400, 600}, {1000, 1200}])
    end
  end

  describe "no oscillation with optional clients" do
    test "solver converges with forbidden windows and optional clients" do
      duration_matrix = [
        [0, 10, 20, 30],
        [10, 0, 10, 20],
        [20, 10, 0, 10],
        [30, 20, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000, service_duration: 10)
        |> Model.add_client(
          x: 10,
          y: 0,
          delivery: [20],
          tw_early: 0,
          tw_late: 1000,
          service_duration: 200,
          required: false,
          prize: 50_000
        )
        |> Model.add_client(
          x: 20,
          y: 0,
          delivery: [20],
          tw_early: 0,
          tw_late: 1000,
          service_duration: 200,
          required: false,
          prize: 50_000
        )
        |> Model.add_client(
          x: 30,
          y: 0,
          delivery: [20],
          tw_early: 0,
          tw_late: 1000,
          service_duration: 200,
          required: false,
          prize: 50_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 400}, {600, 1000}],
          reload_depots: [0],
          max_reloads: 5
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} =
        Solver.solve(model, stop: StoppingCriteria.max_runtime(2), seed: 42)

      solution = result.best
      assert Solution.feasible?(solution)
    end

    @tag timeout: 15_000
    test "solver does not hang with tight forbidden window and many optional clients" do
      clients =
        for i <- 1..8 do
          {i * 5, 0, 10, 0, 1000, 100, false, 30_000}
        end

      model =
        clients
        |> Enum.reduce(
          Model.add_depot(Model.new(), x: 0, y: 0, tw_early: 0, tw_late: 1200, service_duration: 10),
          fn {x, y, delivery, tw_early, tw_late, service_duration, required, prize}, model ->
            Model.add_client(model,
              x: x,
              y: y,
              delivery: [delivery],
              tw_early: tw_early,
              tw_late: tw_late,
              service_duration: service_duration,
              required: required,
              prize: prize
            )
          end
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 300}, {500, 1200}],
          reload_depots: [0],
          max_reloads: 10
        )

      {:ok, result} =
        Solver.solve(model, stop: StoppingCriteria.max_runtime(2), seed: 42)

      solution = result.best
      assert Solution.feasible?(solution)
      assert Solution.num_clients(solution) > 0
    end
  end

  describe "depot removal skipped for forbidden window vehicles" do
    test "reload depots preserved on forbidden window vehicles" do
      duration_matrix = [
        [0, 10, 10],
        [10, 0, 10],
        [10, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 2000, service_duration: 10)
        |> Model.add_client(
          x: 10,
          y: 0,
          delivery: [80],
          tw_early: 0,
          tw_late: 400,
          service_duration: 50,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 10,
          y: 0,
          delivery: [80],
          tw_early: 700,
          tw_late: 1500,
          service_duration: 50,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 500}, {700, 2000}],
          reload_depots: [0],
          max_reloads: 5
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 2000, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.num_clients(solution) == 2

      routes = Solution.routes(solution)
      route = hd(routes)
      assert Route.num_trips(route) > 1
    end
  end

  describe "repair and strip forbidden window violations" do
    test "clients pushed past tw_late by forbidden delay are stripped" do
      duration_matrix = [
        [0, 5, 5],
        [5, 0, 10],
        [5, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 800, service_duration: 10)
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [10],
          tw_early: 0,
          tw_late: 300,
          service_duration: 50,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [10],
          tw_early: 0,
          tw_late: 800,
          service_duration: 300,
          required: false,
          prize: 50_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 200}, {600, 800}],
          reload_depots: [0],
          max_reloads: 5
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 1000, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)

      schedule = Solution.route_schedule(solution, 0)
      assert_no_service_in_forbidden_windows(schedule, [{200, 600}])
    end

    test "repair moves late clients to new trip after forbidden window" do
      duration_matrix = [
        [0, 5, 5, 5],
        [5, 0, 5, 5],
        [5, 5, 0, 5],
        [5, 5, 5, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1500, service_duration: 10)
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [30],
          tw_early: 0,
          tw_late: 300,
          service_duration: 100,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [30],
          tw_early: 0,
          tw_late: 1500,
          service_duration: 100,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [30],
          tw_early: 0,
          tw_late: 1500,
          service_duration: 100,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 400}, {700, 1500}],
          reload_depots: [0],
          max_reloads: 5
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 2000, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.num_clients(solution) >= 2
    end
  end

  describe "multi-trip insertion with forbidden windows" do
    test "clients inserted at correct time-ordered positions" do
      duration_matrix = [
        [0, 5, 5, 5],
        [5, 0, 5, 5],
        [5, 5, 0, 5],
        [5, 5, 5, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 2000, service_duration: 10)
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [10],
          tw_early: 100,
          tw_late: 300,
          service_duration: 30,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [10],
          tw_early: 700,
          tw_late: 900,
          service_duration: 30,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [10],
          tw_early: 1300,
          tw_late: 1500,
          service_duration: 30,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 500}, {700, 1100}, {1300, 2000}],
          reload_depots: [0],
          max_reloads: 10
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 2000, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.num_clients(solution) == 3

      schedule = Solution.route_schedule(solution, 0)
      assert_no_service_in_forbidden_windows(schedule, [{500, 700}, {1100, 1300}])
    end

    test "multi-trip insertion respects shift duration with forbidden delays" do
      duration_matrix = [
        [0, 5, 5],
        [5, 0, 10],
        [5, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1000, service_duration: 10)
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [80],
          tw_early: 0,
          tw_late: 400,
          service_duration: 50,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [80],
          tw_early: 0,
          tw_late: 1000,
          service_duration: 50,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          shift_duration: 1000,
          time_windows: [{0, 400}, {600, 1000}],
          reload_depots: [0],
          max_reloads: 5
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 1000, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.num_clients(solution) == 2
    end
  end

  describe "cost inflation for forbidden window discovery" do
    test "multi-trip preferred over single-trip when forbidden window blocks insertion" do
      duration_matrix = [
        [0, 5, 5],
        [5, 0, 10],
        [5, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1200, service_duration: 10)
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [10],
          tw_early: 0,
          tw_late: 400,
          service_duration: 200,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [10],
          tw_early: 600,
          tw_late: 1200,
          service_duration: 200,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 400}, {600, 1200}],
          reload_depots: [0],
          max_reloads: 5
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 2000, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.num_clients(solution) == 2
    end
  end

  describe "determinism across seeds" do
    test "forbidden window solution is feasible across multiple seeds" do
      duration_matrix = [
        [0, 10, 10, 10],
        [10, 0, 10, 10],
        [10, 10, 0, 10],
        [10, 10, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 2000, service_duration: 10)
        |> Model.add_client(
          x: 10,
          y: 0,
          delivery: [20],
          tw_early: 0,
          tw_late: 400,
          service_duration: 80,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 10,
          y: 0,
          delivery: [20],
          tw_early: 700,
          tw_late: 1200,
          service_duration: 80,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 10,
          y: 0,
          delivery: [20],
          tw_early: 1400,
          tw_late: 2000,
          service_duration: 80,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 500}, {700, 1300}, {1400, 2000}],
          reload_depots: [0],
          max_reloads: 10
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      forbidden_windows = [{500, 700}, {1300, 1400}]

      for seed <- [1, 7, 42, 99, 123] do
        {:ok, result} = Solver.solve(model, max_iterations: 1000, seed: seed)
        solution = result.best

        assert Solution.feasible?(solution),
               "Solution infeasible with seed #{seed}"

        schedule = Solution.route_schedule(solution, 0)
        assert_no_service_in_forbidden_windows(schedule, forbidden_windows)
      end
    end

    defp forbidden_window_multi_seed_model do
      Model.new()
      |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1500, service_duration: 20)
      |> Model.add_client(
        x: 5,
        y: 0,
        delivery: [50],
        tw_early: 0,
        tw_late: 1500,
        service_duration: 100,
        required: false,
        prize: 80_000
      )
      |> Model.add_client(
        x: 10,
        y: 0,
        delivery: [50],
        tw_early: 0,
        tw_late: 1500,
        service_duration: 100,
        required: false,
        prize: 80_000
      )
      |> Model.add_client(
        x: 15,
        y: 0,
        delivery: [50],
        tw_early: 0,
        tw_late: 1500,
        service_duration: 100,
        required: false,
        prize: 80_000
      )
      |> Model.add_client(
        x: 20,
        y: 0,
        delivery: [50],
        tw_early: 0,
        tw_late: 1500,
        service_duration: 100,
        required: false,
        prize: 80_000
      )
      |> Model.add_vehicle_type(
        num_available: 1,
        capacity: [100],
        time_windows: [{0, 400}, {600, 1500}],
        reload_depots: [0],
        max_reloads: 10
      )
    end

    test "no timeout with forbidden windows seed 1" do
      {:ok, result} =
        Solver.solve(forbidden_window_multi_seed_model(), stop: StoppingCriteria.max_runtime(1), seed: 1)

      assert Solution.feasible?(result.best), "Infeasible with seed 1"
    end

    test "no timeout with forbidden windows seed 7" do
      {:ok, result} =
        Solver.solve(forbidden_window_multi_seed_model(), stop: StoppingCriteria.max_runtime(1), seed: 7)

      assert Solution.feasible?(result.best), "Infeasible with seed 7"
    end

    test "no timeout with forbidden windows seed 42" do
      {:ok, result} =
        Solver.solve(forbidden_window_multi_seed_model(), stop: StoppingCriteria.max_runtime(1), seed: 42)

      assert Solution.feasible?(result.best), "Infeasible with seed 42"
    end

    test "no timeout with forbidden windows seed 99" do
      {:ok, result} =
        Solver.solve(forbidden_window_multi_seed_model(), stop: StoppingCriteria.max_runtime(1), seed: 99)

      assert Solution.feasible?(result.best), "Infeasible with seed 99"
    end

    test "no timeout with forbidden windows seed 123" do
      {:ok, result} =
        Solver.solve(forbidden_window_multi_seed_model(), stop: StoppingCriteria.max_runtime(1), seed: 123)

      assert Solution.feasible?(result.best), "Infeasible with seed 123"
    end
  end

  describe "schedule correctness" do
    test "depot wait accounts for forbidden window in schedule output" do
      duration_matrix = [
        [0, 5, 5],
        [5, 0, 5],
        [5, 5, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1200, service_duration: 10)
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [10],
          tw_early: 0,
          tw_late: 300,
          service_duration: 50,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [10],
          tw_early: 700,
          tw_late: 1200,
          service_duration: 50,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 400}, {700, 1200}],
          reload_depots: [0],
          max_reloads: 5
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 2000, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)
      assert Solution.num_clients(solution) == 2

      schedule = Solution.route_schedule(solution, 0)

      # Second client starts after the forbidden window
      client_visits =
        Enum.filter(schedule, fn visit -> visit.location != 0 end)

      second_client = Enum.at(client_visits, 1)

      assert second_client.start_service >= 700,
             "Second client should start after forbidden window ends at 700"
    end

    test "service never overlaps with forbidden window" do
      duration_matrix = [
        [0, 5, 10],
        [5, 0, 5],
        [10, 5, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(x: 0, y: 0, tw_early: 0, tw_late: 1500, service_duration: 10)
        |> Model.add_client(
          x: 5,
          y: 0,
          delivery: [10],
          tw_early: 0,
          tw_late: 1500,
          service_duration: 150,
          required: false,
          prize: 100_000
        )
        |> Model.add_client(
          x: 10,
          y: 0,
          delivery: [10],
          tw_early: 0,
          tw_late: 1500,
          service_duration: 150,
          required: false,
          prize: 100_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          time_windows: [{0, 500}, {700, 1500}],
          reload_depots: [0],
          max_reloads: 5
        )
        |> Model.set_duration_matrices([duration_matrix])
        |> Model.set_distance_matrices([duration_matrix])

      {:ok, result} = Solver.solve(model, max_iterations: 2000, seed: 42)
      solution = result.best

      assert Solution.feasible?(solution)

      schedule = Solution.route_schedule(solution, 0)

      for visit <- schedule, visit.location != 0 do
        service_start = visit.start_service
        service_end = visit.end_service

        refute service_start < 500 and service_end > 500,
               "Service [#{service_start}, #{service_end}] crosses forbidden window start at 500"

        refute service_start >= 500 and service_start < 700,
               "Service starts during forbidden window [500, 700)"
      end
    end
  end
end

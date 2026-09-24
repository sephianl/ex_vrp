defmodule ExVrp.WarmStartRepairTest do
  @moduledoc """
  A warm start describes a plan built for some earlier model, and the model it is handed to is
  never quite that one. Seeding a violation unchanged used to leave the whole run depending on
  the search finding its own way back to feasibility, with nothing in the log to say so.

  These cover the two halves of that: the accessors that make an infeasible solution
  *describable*, and the descent that tries to repair a seed before `IteratedLocalSearch` takes
  it as its incumbent.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Solution

  defp two_vehicle_model do
    Model.new()
    |> Model.add_depot([])
    |> Model.add_vehicle_type(num_available: 1, capacity: [100])
    |> Model.add_vehicle_type(num_available: 1, capacity: [100])
    |> Model.add_client(delivery: [10])
    |> Model.add_client(delivery: [10])
    |> Model.set_euclidean_matrices([{0, 0}, {1, 1}, {2, 2}])
  end

  defp solution_from(model, typed_routes) do
    {:ok, problem_data} = Model.to_problem_data(model)
    {:ok, solution_ref} = Native.create_solution_from_routes_with_types(problem_data, typed_routes)

    solution_ref
  end

  describe "num_same_vehicle_violations/1" do
    @tag :nif_required
    test "is zero for a solution that keeps a group together" do
      model = two_vehicle_model()
      [c1, c2] = model.clients
      model = Model.add_same_vehicle_group(model, [c1, c2])

      solution = solution_from(model, [{0, [1, 2]}])

      assert Native.solution_is_group_feasible(solution)
      assert Native.solution_num_same_vehicle_violations(solution) == 0
    end

    @tag :nif_required
    test "counts a group split across two vehicles" do
      model = two_vehicle_model()
      [c1, c2] = model.clients
      model = Model.add_same_vehicle_group(model, [c1, c2])

      solution = solution_from(model, [{0, [1]}, {1, [2]}])

      refute Native.solution_is_group_feasible(solution)
      assert Native.solution_num_same_vehicle_violations(solution) > 0
    end

    @doc """
    The count is what separates the two constraints `is_group_feasible` collapses together. With
    no same-vehicle group in the model it can only ever be zero, so an infeasible flag alongside
    it points at a client group instead.
    """
    @tag :nif_required
    test "stays zero when the model declares no same-vehicle group" do
      solution = solution_from(two_vehicle_model(), [{0, [1]}, {1, [2]}])

      assert Native.solution_num_same_vehicle_violations(solution) == 0
    end
  end

  describe "Solution.num_same_vehicle_violations/1" do
    @tag :nif_required
    test "is exposed on a solved result" do
      {:ok, result} = ExVrp.solve(two_vehicle_model(), max_iterations: 20, num_starts: 1, seed: 1)

      assert Solution.num_same_vehicle_violations(result.best) == 0
      assert Solution.group_feasible?(result.best)
    end
  end

  describe "an infeasible warm start" do
    # One client whose window closes long before any vehicle could reach it, seeded anyway. The
    # route is structurally valid — every index exists — so the invalid-seed fallback does not
    # fire; it is the schedule that does not hold.
    #
    # Both clients are optional, which is what makes a repair possible at all: with the ex_vrp
    # default of `required: true` an unreachable client makes the model itself infeasible, and
    # there is nothing for any repair to find.
    defp late_window_model do
      Model.new()
      |> Model.add_depot(tw_early: 0, tw_late: 10_000)
      |> Model.add_vehicle_type(num_available: 1, capacity: [100])
      |> Model.add_client(delivery: [10], tw_early: 0, tw_late: 10_000, required: false, prize: 100)
      |> Model.add_client(delivery: [10], tw_early: 0, tw_late: 1, required: false, prize: 100)
      |> Model.set_duration_matrices([[[0, 500, 500], [500, 0, 500], [500, 500, 0]]])
      |> Model.set_distance_matrices([[[0, 500, 500], [500, 0, 500], [500, 500, 0]]])
    end

    @tag :nif_required
    test "is reported rather than seeded silently" do
      log =
        capture_log(fn ->
          {:ok, _result} =
            ExVrp.solve(late_window_model(),
              initial_routes: [[1, 2]],
              max_iterations: 50,
              num_starts: 1,
              seed: 1
            )
        end)

      assert log =~ "Warm start is infeasible"
      assert log =~ "time warp"
    end

    @tag :nif_required
    test "leaves the solver with a feasible incumbent" do
      {:ok, result} =
        ExVrp.solve(late_window_model(),
          initial_routes: [[1, 2]],
          max_iterations: 50,
          num_starts: 1,
          seed: 1
        )

      assert Solution.feasible?(result.best)
    end
  end

  describe "an unrepairable warm start" do
    @doc """
    A required client nothing can reach makes the model itself infeasible, so no repair exists.
    The run still has to say what was wrong: "no violation reported" was the original hole here,
    because completeness is a feasibility condition that none of the amount-based checks see.
    """
    @tag :nif_required
    test "names the completeness violation rather than reporting nothing" do
      model =
        Model.new()
        |> Model.add_depot(tw_early: 0, tw_late: 10_000)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(delivery: [10], tw_early: 0, tw_late: 10_000)
        |> Model.add_client(delivery: [10], tw_early: 0, tw_late: 1)
        |> Model.set_duration_matrices([[[0, 500, 500], [500, 0, 500], [500, 500, 0]]])
        |> Model.set_distance_matrices([[[0, 500, 500], [500, 0, 500], [500, 500, 0]]])

      log =
        capture_log(fn ->
          {:ok, _result} =
            ExVrp.solve(model, initial_routes: [[1, 2]], max_iterations: 50, num_starts: 1, seed: 1)
        end)

      assert log =~ "Warm start could not be repaired"
      refute log =~ "no violation reported"
      refute log =~ "Initial solution is infeasible"
    end
  end

  describe "a warm start a descent cannot repair" do
    @doc """
    The case the descent alone loses. Two clients are pinned to one vehicle by a same-vehicle
    group, so the relocation that would relieve the route is forbidden; the descent can only
    take clients on, and a client's prize outweighs a finite violation penalty. Both clients are
    optional here, so giving one up is a move the trim is allowed to make.
    """
    @tag :nif_required
    test "drops visits until the seed is feasible" do
      model =
        Model.new()
        |> Model.add_depot(tw_early: 0, tw_late: 10_000)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(delivery: [10], tw_early: 0, tw_late: 10_000, required: false, prize: 100_000)
        |> Model.add_client(delivery: [10], tw_early: 0, tw_late: 1, required: false, prize: 100_000)
        |> Model.set_duration_matrices([[[0, 900, 900], [900, 0, 900], [900, 900, 0]]])
        |> Model.set_distance_matrices([[[0, 900, 900], [900, 0, 900], [900, 900, 0]]])

      [c1, c2] = model.clients
      model = Model.add_same_vehicle_group(model, [c1, c2])

      log =
        capture_log(fn ->
          {:ok, result} =
            ExVrp.solve(model, initial_routes: [[1, 2]], max_iterations: 50, num_starts: 1, seed: 1)

          assert Solution.feasible?(result.best)
        end)

      assert log =~ "Warm start is infeasible"
      refute log =~ "could not be repaired"
    end

    @doc """
    The same trim on a seed that reloads. Two trips of capacity two cannot carry five clients, and
    each client's prize outweighs the overload penalty, so the descent keeps them all. The trim
    rebuilds every candidate trip by trip, and has to keep the reload to land on four clients.
    """
    @tag :nif_required
    test "drops visits from a multi-trip seed until it is feasible, keeping its trips" do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      model =
        1..5
        |> Enum.reduce(Model.add_depot(Model.new(), []), fn _client, acc ->
          Model.add_client(acc, delivery: [1], required: false, prize: 10_000_000)
        end)
        |> Model.add_vehicle_type(num_available: 1, capacity: [2], reload_depots: [0], max_reloads: 1)
        |> Model.set_euclidean_matrices([{0, 0}, {10, 0}, {20, 0}, {30, 0}, {0, 10}, {0, 20}])

      seed = [{:trips, [%{reload_depot: nil, clients: [1, 2, 3]}, %{reload_depot: 0, clients: [4, 5]}]}]

      log =
        capture_log(fn ->
          {:ok, result} = ExVrp.solve(model, initial_routes: seed, max_iterations: 0, num_starts: 1, seed: 1)

          assert Solution.feasible?(result.best)
          assert Solution.num_clients(result.best) == 4
          assert [[_first, _second]] = Native.solution_trips(result.best.solution_ref)
        end)

      assert log =~ "Warm start is infeasible"
      assert log =~ "Warm start repair dropped 1 visit(s)"
      refute log =~ "could not be repaired"
    end

    @doc """
    The other half of that bargain. Feasibility also demands every required client be visited, so
    where the clients are required there is no removal that gets closer to it — dropping one trades
    the time warp for a missing client and leaves the seed no more usable than before. Trimming has
    to recognise it has nothing to offer and hand the descent's own plan over whole, rather than
    spending the plan on a feasibility it cannot reach.
    """
    @tag :nif_required
    test "hands over an unreachable seed intact rather than emptying it" do
      clients = 10
      far = List.duplicate(900, clients + 1)
      matrix = for row <- 0..clients, do: List.replace_at(far, row, 0)

      model =
        Enum.reduce(1..clients, base_model(), fn client, acc ->
          Model.add_client(acc, delivery: [1], tw_early: 0, tw_late: tw_late_for(client, clients))
        end)

      model =
        model
        |> Model.set_duration_matrices([matrix])
        |> Model.set_distance_matrices([matrix])

      log =
        capture_log(fn ->
          {:ok, result} =
            ExVrp.solve(model, initial_routes: [Enum.to_list(1..clients)], max_iterations: 1, num_starts: 1, seed: 1)

          assert Solution.num_clients(result.best) == clients
        end)

      assert log =~ "could not be repaired"
      refute log =~ "required clients unvisited"
      refute log =~ "dropped"
    end
  end

  defp base_model do
    Model.new()
    |> Model.add_depot(tw_early: 0, tw_late: 100_000)
    |> Model.add_vehicle_type(num_available: 1, capacity: [1_000])
  end

  defp tw_late_for(client, client), do: 1
  defp tw_late_for(_client, _last), do: 100_000

  describe "an invalid warm start" do
    @doc """
    A structurally invalid seed falls back to a descent from empty. What the run reports has to
    follow what it actually did, not what was asked for: the old message read the request off
    `:initial_routes` and blamed a warm start that had already been discarded.
    """
    @tag :nif_required
    test "is reported as the cold start it fell back to" do
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: :warning) end)

      model =
        Model.new()
        |> Model.add_depot(tw_early: 0, tw_late: 10_000)
        |> Model.add_vehicle_type(num_available: 1, capacity: [100])
        |> Model.add_client(delivery: [10], tw_early: 0, tw_late: 10_000)
        |> Model.add_client(delivery: [10], tw_early: 0, tw_late: 1)
        |> Model.set_duration_matrices([[[0, 500, 500], [500, 0, 500], [500, 500, 0]]])
        |> Model.set_distance_matrices([[[0, 500, 500], [500, 0, 500], [500, 500, 0]]])

      log =
        capture_log(fn ->
          {:ok, _result} =
            ExVrp.solve(model, initial_routes: [[1, 2, 99]], max_iterations: 50, num_starts: 1, seed: 1)
        end)

      assert log =~ ":initial_routes is invalid, falling back to empty start"
      assert log =~ "One descent from empty does not always reach feasibility"
      refute log =~ "Warm start"
    end
  end

  describe "a feasible warm start" do
    @tag :nif_required
    test "is handed over untouched" do
      log =
        capture_log(fn ->
          {:ok, result} =
            ExVrp.solve(two_vehicle_model(),
              initial_routes: [[1, 2]],
              max_iterations: 20,
              num_starts: 1,
              seed: 1
            )

          assert Solution.feasible?(result.best)
        end)

      refute log =~ "Warm start is infeasible"
      refute log =~ "INFEASIBLE before any search ran"
    end
  end
end

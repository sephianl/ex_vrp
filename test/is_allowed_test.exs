defmodule ExVrp.IsAllowedTest do
  @moduledoc """
  Tests for the per-profile reachability predicate.

  Forbidden locations are pruned by local search rather than merely costed,
  which is what distinguishes them from a large penalty: no prize outbids a
  forbidden location.

  Reachability used to be inferred from a 1e9 distance, which meant the
  constraint enforced itself through the objective — any move onto a
  forbidding route was so expensive that no operator would take it. With the
  predicate explicit and the distance channel free to carry real distances,
  that accidental enforcement is gone and every path that places a client has
  to check for itself. Three did not, and all three are covered below: the
  in-place swaps, the route operators, and the node operators that move more
  than the node they are named after.

  Because of that, most tests here assert the *invariant* — no route visits a
  location its own profile forbids — over a sweep of seeds rather than one
  outcome on one model. Every bug found while writing this file was invisible
  to a single-seed assertion on a single shape.

  The node-operator tests go further and drive local search directly from a
  fixed starting solution, because the shapes that expose those leaks are ones
  the solver only reaches by luck: a segment whose *second* client is the
  forbidden one, or a tail swap that no Exchange<N, M> can replicate.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Solution
  alias ExVrp.Solver

  defp solve(model) do
    Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(500))
  end

  # One depot and two optional clients, reachable by two vehicles on two
  # profiles with identical matrices. Prizes dwarf any travel cost, so only
  # the pruning predicate can keep a client out of the solution.
  defp model_with(forbidden) do
    matrix = [
      [0, 10, 10],
      [10, 0, 10],
      [10, 10, 0]
    ]

    Model.new()
    |> Model.add_depot(tw_late: 1000)
    |> Model.add_client(
      delivery: [0],
      service_duration: 0,
      tw_early: 0,
      tw_late: 1000,
      required: false,
      prize: 10_000_000
    )
    |> Model.add_client(
      delivery: [0],
      service_duration: 0,
      tw_early: 0,
      tw_late: 1000,
      required: false,
      prize: 10_000_000
    )
    # Profile 1 is 100x cheaper, so the solver always prefers it. That makes
    # the assignment deterministic: only forbidding can push a client onto
    # the expensive profile-0 vehicle. With two identical vehicles the choice
    # would be arbitrary and the assertion would pass whether or not the
    # predicate works.
    |> Model.add_vehicle_type(
      num_available: 1,
      capacity: [100],
      unit_distance_cost: 100,
      profile: 0
    )
    |> Model.add_vehicle_type(
      num_available: 1,
      capacity: [100],
      unit_distance_cost: 1,
      profile: 1
    )
    |> Model.set_distance_matrices([matrix, matrix])
    |> Model.set_duration_matrices([matrix, matrix])
    |> Model.set_forbidden(forbidden)
  end

  defp visited(solution) do
    solution |> Solution.routes() |> Enum.flat_map(& &1.visits)
  end

  defp carrier(solution, location) do
    solution
    |> Solution.routes()
    |> Enum.find(&(location in &1.visits))
  end

  test "both clients are served on the cheap profile when nothing is forbidden" do
    {:ok, result} = solve(model_with([]))

    assert Solution.num_clients(result.best) == 2
    assert 1 in visited(result.best)

    # Establishes the baseline the next test inverts: left alone, the solver
    # puts everything on the profile-1 vehicle.
    assert carrier(result.best, 1).vehicle_type == 1
  end

  test "a location forbidden on every profile is never visited" do
    # Location 1 is the first client. No vehicle may reach it, and its prize
    # cannot buy its way in.
    {:ok, result} = solve(model_with([[1], [1]]))

    solution = result.best

    assert Solution.num_clients(solution) == 1
    refute 1 in visited(solution)
  end

  describe "single-profile models" do
    # A car-only fleet with uniform zone exemptions collapses to one profile,
    # which is an ordinary production shape rather than a corner case. Before
    # forbidding was explicit, reachability was inferred from a huge distance,
    # so a single-profile model could not express "unreachable" without also
    # being ruinously expensive. Now it can — and the location must actually
    # be pruned, or it becomes free to visit.
    defp single_profile_model(forbidden) do
      matrix = [
        [0, 10, 10],
        [10, 0, 10],
        [10, 10, 0]
      ]

      Model.new()
      |> Model.add_depot(tw_late: 1000)
      |> Model.add_client(
        delivery: [0],
        service_duration: 0,
        tw_early: 0,
        tw_late: 1000,
        required: false,
        prize: 10_000_000
      )
      |> Model.add_client(
        delivery: [0],
        service_duration: 0,
        tw_early: 0,
        tw_late: 1000,
        required: false,
        prize: 10_000_000
      )
      |> Model.add_vehicle_type(
        num_available: 2,
        capacity: [100],
        unit_distance_cost: 1
      )
      |> Model.set_distance_matrices([matrix])
      |> Model.set_duration_matrices([matrix])
      |> Model.set_forbidden(forbidden)
    end

    test "both clients are served when nothing is forbidden" do
      {:ok, result} = solve(single_profile_model([]))

      assert Solution.num_clients(result.best) == 2
    end

    test "a forbidden location is pruned even with only one profile" do
      {:ok, result} = solve(single_profile_model([[1]]))

      solution = result.best

      assert Solution.num_clients(solution) == 1
      refute 1 in visited(solution)
    end
  end

  describe "same-vehicle groups" do
    # Exercises the group-placement site in LocalSearch: a group may only go
    # to a route whose profile allows *every* member. Forbidding one member
    # on the cheap profile must move the whole group, not just that member.
    defp group_model(forbidden) do
      matrix = [
        [0, 10, 10, 10],
        [10, 0, 10, 10],
        [10, 10, 0, 10],
        [10, 10, 10, 0]
      ]

      model =
        Enum.reduce(1..3, Model.add_depot(Model.new(), tw_late: 1000), fn _i, acc ->
          Model.add_client(acc,
            delivery: [0],
            service_duration: 0,
            tw_early: 0,
            tw_late: 1000,
            required: false,
            prize: 10_000_000
          )
        end)

      model
      # Clients 0 and 1 are locations 1 and 2.
      |> Model.add_same_vehicle_group([0, 1])
      |> Model.add_vehicle_type(
        num_available: 1,
        capacity: [100],
        unit_distance_cost: 100,
        profile: 0
      )
      |> Model.add_vehicle_type(
        num_available: 1,
        capacity: [100],
        unit_distance_cost: 1,
        profile: 1
      )
      |> Model.set_distance_matrices([matrix, matrix])
      |> Model.set_duration_matrices([matrix, matrix])
      |> Model.set_forbidden(forbidden)
    end

    test "an unrestricted group takes the cheap profile" do
      {:ok, result} = solve(group_model([]))
      solution = result.best

      assert carrier(solution, 1).vehicle_type == 1
      assert carrier(solution, 2).vehicle_type == 1
    end

    test "forbidding one member moves the whole group to the allowed profile" do
      # Only location 1 is forbidden on profile 1, but location 2 is bound to
      # it by the group, so both must end up on the profile-0 vehicle.
      {:ok, result} = solve(group_model([[], [1]]))
      solution = result.best

      assert Solution.num_clients(solution) == 3
      assert carrier(solution, 1).vehicle_type == 0
      assert carrier(solution, 2).vehicle_type == 0

      # The ungrouped client is free to stay where it is cheapest.
      assert carrier(solution, 3).vehicle_type == 1
    end
  end

  describe "three profiles" do
    # numProfiles() > 2 is the only case where isHardToPlace does anything,
    # and it is the site whose depot probe isAllowed replaced.
    test "a location allowed on only one of three profiles lands there" do
      matrix = [
        [0, 10, 10],
        [10, 0, 10],
        [10, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(tw_late: 1000)
        |> Model.add_client(
          delivery: [0],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 10_000_000
        )
        |> Model.add_client(
          delivery: [0],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 10_000_000
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          unit_distance_cost: 1000,
          profile: 0
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          unit_distance_cost: 100,
          profile: 1
        )
        |> Model.add_vehicle_type(
          num_available: 1,
          capacity: [100],
          unit_distance_cost: 1,
          profile: 2
        )
        |> Model.set_distance_matrices([matrix, matrix, matrix])
        |> Model.set_duration_matrices([matrix, matrix, matrix])
        # Location 1 is allowed only on the most expensive profile.
        |> Model.set_forbidden([[], [1], [1]])

      {:ok, result} = solve(model)
      solution = result.best

      assert Solution.num_clients(solution) == 2
      assert carrier(solution, 1).vehicle_type == 0
      assert carrier(solution, 2).vehicle_type == 2
    end
  end

  describe "robustness" do
    test "forbidding a depot is rejected" do
      # Location 0 is the depot. A vehicle starts and ends there regardless, so
      # the restriction cannot be honoured — and accepting it quietly would
      # hand the caller a rule that does nothing.
      assert {:error, [message]} = Model.validate(model_with([[0], [0]]))
      assert message =~ "a depot cannot be forbidden"
    end

    test "an out-of-range forbidden index is rejected" do
      # Dropping it is the worst outcome: the caller asked for a restriction,
      # got none, and is never told.
      assert {:error, [message]} = Model.validate(model_with([[99], [99]]))
      assert message =~ "must be client indices within 1..2"
    end

    test "the C++ layer rejects the same indices if validation is bypassed" do
      # Validation is the guard, but Native.create_problem_data/1 is reachable
      # directly, so the decode refuses these too rather than dropping them.
      assert_raise ArgumentError, ~r/Cannot forbid a depot/, fn ->
        ExVrp.Native.create_problem_data(model_with([[0], [0]]))
      end

      assert_raise ArgumentError, ~r/out of range/, fn ->
        ExVrp.Native.create_problem_data(model_with([[99], [99]]))
      end
    end

    test "the C++ layer rejects a negative penalty if validation is bypassed" do
      model = Model.set_penalties(model_with([]), [[0, -5, 0], [0, 0, 0]])

      assert_raise ArgumentError, ~r/non-negative/, fn ->
        ExVrp.Native.create_problem_data(model)
      end
    end

    test "a profile may forbid every client" do
      # Profile 1 can serve nothing, so the profile-0 vehicle takes both even
      # though profile 1 is cheaper.
      {:ok, result} = solve(model_with([[], [1, 2]]))
      solution = result.best

      assert Solution.num_clients(solution) == 2
      assert carrier(solution, 1).vehicle_type == 0
      assert carrier(solution, 2).vehicle_type == 0
    end

    test "fewer forbidden lists than profiles is rejected, not silently mis-indexed" do
      # One list for two profiles. The dangerous outcome would be applying
      # profile 0's restrictions to profile 1, or reading past the end.
      assert {:error, [message]} = Model.validate(model_with([[1]]))
      assert message =~ "one forbidden list per routing profile (2)"
    end

    test "the C++ layer rejects the same shape if validation is bypassed" do
      assert_raise ArgumentError, ~r/one allowed set per profile/, fn ->
        ExVrp.Native.create_problem_data(model_with([[1]]))
      end
    end
  end

  describe "multi-trip routes" do
    # improveWithMultiTrip inserts unassigned clients as a new trip, choosing
    # a route itself rather than going through Solution::insert. It only fires
    # for vehicle types with reload depots — which is the shape Zelo runs.
    #
    # Honest caveat: the reachability check on that path is defensive. These
    # tests do not force it to fire — disabling the check leaves them green,
    # and instrumenting the insertion showed nothing in the suite reaching it
    # with a forbidden client. The check is one comparison and the path
    # provably lacks one otherwise, so it stays; but do not read these tests
    # as proving it. A model that reliably strands a forbidden client while
    # leaving a reload-capable route with spare trips would.
    defp multi_trip_model(forbidden) do
      matrix = [
        [0, 10, 10],
        [10, 0, 10],
        [10, 10, 0]
      ]

      client = [
        delivery: [1],
        service_duration: 0,
        tw_early: 0,
        tw_late: 100_000,
        required: false,
        prize: 10_000_000
      ]

      Model.new()
      |> Model.add_depot(tw_late: 100_000)
      |> Model.add_client(client)
      |> Model.add_client(client)
      # Capacity 1 forces a reload between the two clients.
      |> Model.add_vehicle_type(
        num_available: 1,
        capacity: [1],
        unit_distance_cost: 100,
        profile: 0,
        reload_depots: [0],
        time_windows: [{0, 100_000}]
      )
      |> Model.add_vehicle_type(
        num_available: 1,
        capacity: [1],
        unit_distance_cost: 1,
        profile: 1,
        reload_depots: [0],
        time_windows: [{0, 100_000}]
      )
      |> Model.set_distance_matrices([matrix, matrix])
      |> Model.set_duration_matrices([matrix, matrix])
      |> Model.set_forbidden(forbidden)
    end

    test "a forbidden client is not added as a new trip on a barred vehicle" do
      assert violations(multi_trip_model([[], [1]]), [[], [1]], 1..12) == []
    end

    test "multi-trip still serves everything when nothing is forbidden" do
      {:ok, result} = solve(multi_trip_model([]))

      assert Solution.num_clients(result.best) == 2
    end
  end

  describe "moves that carry more than U and V across" do
    # The node operators disagree about which nodes actually change route.
    # Exchange<2, *> carries n(U) along with U, and SwapTails carries both
    # whole tails, so checking only U and V lets a forbidden client ride across
    # as a passenger. Both models below are built so the illegal move is the
    # profitable one, and both are driven through the local search directly
    # from a fixed starting solution rather than through the solver, so what
    # they cover does not depend on the solver happening to reach the shape.
    alias ExVrp.Native

    @local_search_seeds 1..12

    defp evaluator do
      {:ok, evaluator} =
        Native.create_cost_evaluator(
          load_penalties: [100.0],
          tw_penalty: 100.0,
          dist_penalty: 100.0
        )

      evaluator
    end

    defp local_search_from(model, routes) do
      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, initial} = Native.create_solution_from_routes_with_types(problem_data, routes)

      for seed <- @local_search_seeds do
        {:ok, improved} = Native.local_search(initial, problem_data, evaluator(), seed: seed)
        {seed, improved}
      end
    end

    defp native_violations(solutions, forbidden_by_profile) do
      for {seed, solution} <- solutions,
          {visits, idx} <- Enum.with_index(Native.solution_routes(solution)),
          banned =
            Enum.at(forbidden_by_profile, Native.solution_route_vehicle_type(solution, idx), []),
          location <- visits,
          location in banned do
        {seed, location}
      end
    end

    # Every pair not named takes `default`, which is what keeps the alternative
    # moves unattractive and leaves only the illegal one worth making.
    defp distances(size, weights, default) do
      lookup =
        for {pairs, value} <- weights,
            {i, j} <- pairs,
            key <- [{i, j}, {j, i}],
            into: %{},
            do: {key, value}

      for i <- 0..(size - 1), do: distance_row(i, size, lookup, default)
    end

    defp distance_row(i, size, lookup, default) do
      for j <- 0..(size - 1), do: distance_between(i, j, lookup, default)
    end

    defp distance_between(i, i, _lookup, _default), do: 0
    defp distance_between(i, j, lookup, default), do: Map.get(lookup, {i, j}, default)

    defp two_profile_model(matrix, unit_costs, forbidden) do
      [dear, cheap] = unit_costs

      1..(length(matrix) - 1)
      |> Enum.reduce(Model.add_depot(Model.new(), tw_late: 100_000), fn _index, model ->
        Model.add_client(model,
          delivery: [1],
          service_duration: 0,
          tw_early: 0,
          tw_late: 100_000
        )
      end)
      |> Model.add_vehicle_type(
        num_available: 1,
        capacity: [100],
        unit_distance_cost: dear,
        profile: 0
      )
      |> Model.add_vehicle_type(
        num_available: 1,
        capacity: [100],
        unit_distance_cost: cheap,
        profile: 1
      )
      |> Model.set_distance_matrices([matrix, matrix])
      |> Model.set_duration_matrices([matrix, matrix])
      |> Model.set_forbidden(forbidden)
    end

    # Route A (profile 0, dear) is 0-1-2; route B (profile 1, cheap) is 0-3.
    # Clients 1 and 2 are a tight pair and 2 is barred from profile 1, so
    # relocating 1 on its own is not worth it while carrying the pair across
    # is. Exchange<2, 0> and Exchange<2, 1> both take client 2 along.
    defp exchange_model(forbidden) do
      4
      |> distances([{[{0, 1}, {0, 2}, {0, 3}], 10}, {[{1, 2}, {2, 3}], 1}], 1000)
      |> two_profile_model([100, 1], forbidden)
    end

    # Route A (profile 0) is 0-1-2-5-6; route B (profile 1) is 0-3-4-7-8. The
    # edges 1->2 and 3->4 are ruinous while 1->4 and 3->2 are free, so swapping
    # the tails behind 1 and 3 is hugely improving. Those tails are three
    # clients long — beyond the reach of every Exchange<N, M> the solver has —
    # so only SwapTails finds it, and it drags client 2 across as a passenger.
    defp tail_swap_model(forbidden) do
      9
      |> distances(
        [
          {[{0, 1}, {0, 3}, {0, 6}, {0, 8}, {2, 5}, {5, 6}, {4, 7}, {7, 8}], 10},
          {[{1, 2}, {3, 4}], 1000},
          {[{1, 4}, {3, 2}], 1}
        ],
        4000
      )
      |> two_profile_model([1, 1], forbidden)
    end

    @tail_swap_routes [{0, [1, 2, 5, 6]}, {1, [3, 4, 7, 8]}]

    test "Exchange does not carry a forbidden client along as the second of a pair" do
      solutions = local_search_from(exchange_model([[], [2]]), [{0, [1, 2]}, {1, [3]}])

      assert native_violations(solutions, [[], [2]]) == []
    end

    test "SwapTails does not carry a forbidden client across in a tail" do
      solutions = local_search_from(tail_swap_model([[], [2]]), @tail_swap_routes)

      assert native_violations(solutions, [[], [2]]) == []
    end

    test "the tail swap is still found when nothing is forbidden" do
      # Guards against fixing the leak by simply refusing the move: with the
      # bar lifted, the same instance must still reach the crossing optimum.
      # Without this, gating everything unconditionally would pass above.
      costs =
        for {_seed, solution} <- local_search_from(tail_swap_model([[], []]), @tail_swap_routes),
            do: Native.solution_penalised_cost(solution, evaluator())

      assert 82 in costs
    end
  end

  describe "the forbidding invariant across solver seeds" do
    # Both bugs found while writing this file were seed- and shape-dependent
    # and invisible to a single-seed assertion on one model: an in-place swap
    # that inserted without checking, and the route operators, which exchange
    # clients across profiles and used to be guarded only by the 1e9 distance
    # making such a move non-improving.
    #
    # So rather than assert an outcome, assert the invariant: no route ever
    # visits a location its own profile forbids. Vehicle type i uses profile i
    # in every model here.
    defp violations(model, forbidden_by_profile, seeds) do
      for seed <- seeds,
          route <-
            (fn ->
               {:ok, r} =
                 Solver.solve(model,
                   stop: ExVrp.StoppingCriteria.max_iterations(500),
                   seed: seed
                 )

               Solution.routes(r.best)
             end).(),
          banned = Enum.at(forbidden_by_profile, route.vehicle_type, []),
          location <- route.visits,
          location in banned do
        {seed, route.vehicle_type, location}
      end
    end

    @seeds 1..12

    test "single profile" do
      assert violations(single_profile_model([[1]]), [[1]], @seeds) == []
    end

    test "two profiles" do
      assert violations(model_with([[], [1]]), [[], [1]], @seeds) == []
    end

    test "two profiles, everything forbidden on one" do
      assert violations(model_with([[], [1, 2]]), [[], [1, 2]], @seeds) == []
    end

    test "with penalties in play" do
      model =
        [[2]]
        |> single_profile_model()
        |> Model.set_penalties([[0, 5_000, 0]])

      assert violations(model, [[2]], @seeds) == []
    end

    test "with a same-vehicle group" do
      assert violations(group_model([[], [1]]), [[], [1]], @seeds) == []
    end
  end

  describe "model validation" do
    # These shapes used to reach the NIF and come back as a std::invalid_argument,
    # or in the negative-penalty case not be caught at all. Every other shape
    # check in the model is reported through validate/1, and so are these.
    test "a penalty list of the wrong length is rejected" do
      model = Model.set_penalties(model_with([]), [[0, 0], [0, 0, 0]])

      assert {:error, messages} = Model.validate(model)
      assert Enum.any?(messages, &(&1 =~ "one cost per location"))
    end

    test "a negative penalty is rejected" do
      # Non-negativity is load-bearing: CostEvaluator's delta shortcut assumes
      # a penalty can only ever raise the cost of a move.
      model = Model.set_penalties(model_with([]), [[0, -5, 0], [0, 0, 0]])

      assert {:error, messages} = Model.validate(model)
      assert Enum.any?(messages, &(&1 =~ "non-negative"))
    end

    test "a nonzero depot penalty is rejected" do
      model = Model.set_penalties(model_with([]), [[7, 0, 0], [0, 0, 0]])

      assert {:error, messages} = Model.validate(model)
      assert Enum.any?(messages, &(&1 =~ "Depot penalties must be zero"))
    end

    test "one penalty list per profile is required" do
      model = Model.set_penalties(model_with([]), [[0, 0, 0]])

      assert {:error, messages} = Model.validate(model)
      assert Enum.any?(messages, &(&1 =~ "one penalty list per routing profile (2)"))
    end

    test "well-formed penalties and forbidden lists validate" do
      model = Model.set_penalties(model_with([[], [1]]), [[0, 500, 0], [0, 0, 0]])

      assert Model.validate(model) == :ok
    end
  end

  describe "the reporting backstop" do
    test "a solved solution reports no forbidden visits" do
      {:ok, result} = solve(model_with([[], [1]]))

      assert Solution.num_forbidden_visits(result.best) == 0
    end

    test "it counts visits the route's own profile forbids" do
      # Built by hand rather than by the solver, which is the point: the count
      # is what makes a violation visible when something places one, and the
      # only way to place one today is to bypass the search entirely.
      model = model_with([[], [1]])
      {:ok, problem_data} = Model.to_problem_data(model)

      # Vehicle type 1 runs on profile 1, which bars location 1.
      {:ok, solution} =
        ExVrp.Native.create_solution_from_routes_with_types(problem_data, [{1, [1, 2]}])

      assert ExVrp.Native.solution_num_forbidden_visits(solution) == 1
    end

    test "an allowed assignment of the same clients reports none" do
      model = model_with([[], [1]])
      {:ok, problem_data} = Model.to_problem_data(model)

      {:ok, solution} =
        ExVrp.Native.create_solution_from_routes_with_types(problem_data, [{0, [1, 2]}])

      assert ExVrp.Native.solution_num_forbidden_visits(solution) == 0
    end
  end

  describe "penalties and forbidding together" do
    test "a penalised location is served while a forbidden one is not" do
      matrix = [
        [0, 10, 10],
        [10, 0, 10],
        [10, 10, 0]
      ]

      model =
        Model.new()
        |> Model.add_depot(tw_late: 1000)
        |> Model.add_client(
          delivery: [0],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 10_000_000
        )
        |> Model.add_client(
          delivery: [0],
          service_duration: 0,
          tw_early: 0,
          tw_late: 1000,
          required: false,
          prize: 10_000_000
        )
        |> Model.add_vehicle_type(
          num_available: 2,
          capacity: [100],
          unit_distance_cost: 1
        )
        |> Model.set_distance_matrices([matrix])
        |> Model.set_duration_matrices([matrix])
        # Location 1 is merely expensive; location 2 is off limits.
        |> Model.set_penalties([[0, 5_000, 0]])
        |> Model.set_forbidden([[2]])

      {:ok, result} = solve(model)
      solution = result.best

      # The prize dwarfs the penalty, so location 1 is worth serving; no
      # prize reaches location 2.
      assert Solution.num_clients(solution) == 1
      assert 1 in visited(solution)
      refute 2 in visited(solution)
      assert Solution.penalty_cost(solution) == 5_000
    end
  end

  test "a location forbidden on one profile is served by the other" do
    # Forbidden on profile 1 only. The solver would rather put it on the
    # cheap profile-1 vehicle — the baseline test above proves it does when
    # allowed — so landing on the expensive profile-0 vehicle can only be
    # the predicate's doing.
    {:ok, result} = solve(model_with([[], [1]]))

    solution = result.best

    assert Solution.num_clients(solution) == 2
    assert carrier(solution, 1).vehicle_type == 0

    # Location 2 is unrestricted and stays where it is cheapest.
    assert carrier(solution, 2).vehicle_type == 1
  end
end

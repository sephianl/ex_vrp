defmodule ExVrp.Solver do
  @moduledoc """
  Main solver interface for VRP problems.

  This module provides the `solve/2` function which is a direct port of PyVRP's
  `solve()` function. It sets up the solver components and runs Iterated Local
  Search with Late Acceptance Hill-Climbing.
  """

  alias ExVrp.IteratedLocalSearch
  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.PenaltyManager
  alias ExVrp.StoppingCriteria

  require Logger

  @type solve_opts :: [
          max_iterations: pos_integer(),
          max_runtime: pos_integer(),
          stop: StoppingCriteria.t(),
          seed: non_neg_integer(),
          num_starts: pos_integer() | :auto,
          penalty_params: PenaltyManager.Params.t(),
          ils_params: IteratedLocalSearch.Params.t(),
          on_progress: (map() -> any()) | nil,
          initial_routes: [Native.warm_start_visits()] | nil,
          log_label: String.t() | nil
        ]

  @default_opts [
    max_iterations: 10_000,
    max_runtime: nil,
    stop: nil,
    seed: nil,
    num_starts: :auto,
    penalty_params: nil,
    ils_params: nil,
    on_progress: nil,
    initial_routes: nil,
    log_label: nil
  ]

  @repair_budget_share 0.25

  # A backstop, not a budget: each accepted step drops one visit, so the loop is bounded by the
  # seed's own visit count long before this. Hitting it means the trim is not converging, and the
  # descent's own result is handed over rather than spinning.
  @max_repair_drops 1_000

  @doc """
  Solves a VRP model using Iterated Local Search.

  This is a port of PyVRP's `solve()` function. It:
  1. Creates the problem data from the model
  2. Initializes the PenaltyManager for dynamic penalty adjustment
  3. Creates an initial solution using local search on empty solution
  4. Runs Iterated Local Search until stopping criterion is met

  ## Options

  - `:max_iterations` - Maximum number of iterations (default: 10_000)
  - `:max_runtime` - Maximum runtime in milliseconds (default: unlimited). Note that
    `StoppingCriteria.max_runtime/1` takes seconds instead, matching PyVRP's `MaxRuntime`.
  - `:stop` - Custom StoppingCriteria (overrides max_iterations/max_runtime)
  - `:seed` - Random seed for reproducibility (default: random)
  - `:num_starts` - Number of parallel independent solver starts (default: `:auto`).
    Each start uses a different seed and runs its own ILS chain.
    The best result across all starts is returned.
    Use `:auto` to pick based on available cores (`div(schedulers_online, 2)`).
  - `:penalty_params` - PenaltyManager.Params for penalty adjustment
  - `:ils_params` - IteratedLocalSearch.Params for ILS behavior
  - `:on_progress` - Optional callback function receiving progress maps during ILS iterations (time-gated at ~1s intervals). When `num_starts > 1`, progress maps include `:seed_idx` and `:seed` fields.
  - `:log_label` - Optional string folded into this solve's log lines, e.g.
    `log_label: "relaxed_15"` yields `[exvrp relaxed_15 start 2] ILS completed in ...`.
    Start indices only distinguish chains *within* one `solve/2` call, so a host that
    runs several solves concurrently needs this to tell their log lines apart.
  - `:initial_routes` - Optional warm-start. A list of routes where the position
    in the outer list maps to the vehicle type index. Each inner list is a
    sequence of client IDs visited by that vehicle type. Empty inner lists are
    skipped (vehicle type unused in the warm-start). When provided, the solver
    skips the empty-solution local-search step and uses these routes as the
    initial solution directly. Example: `[[1, 2, 3], [], [4, 5]]` warm-starts
    with vehicle type 0 visiting clients 1, 2, 3 and vehicle type 2 visiting 4, 5.

    A flat client list is a single trip. A vehicle type that reloads is seeded
    trip by trip with `{:trips, [%{reload_depot: depot_idx | nil, clients: [client_idx]}]}`:
    the first trip's `reload_depot` is `nil` (it starts at the vehicle type's
    start depot), and each later trip names the reload depot it starts from.
    Example: `[{:trips, [%{reload_depot: nil, clients: [1, 2]}, %{reload_depot: 0, clients: [3, 4]}]}]`
    warm-starts vehicle type 0 with clients 1, 2, a reload at depot 0, then
    clients 3, 4. `ExVrp.Native.solution_trips/1` reads a solution's trips back.

    Capacity-overloaded and time-window-violating starts are passed through to
    the solver — these are valid infeasible starting points that the solver can
    repair via penalties. Structurally invalid inputs (duplicate clients,
    out-of-range vehicle types or client IDs, too many routes for
    `num_available`, a reload depot not in the vehicle type's `reload_depots`,
    more trips than its `max_reloads + 1`) are logged as warnings and the
    solver falls back to a cold (empty) start rather than crashing.

  ## Returns

  - `{:ok, result}` - Successfully found a solution. Result has:
    - `result.best` - Best Solution found
    - `result.cost()` - Cost of best solution (infinity if infeasible)
    - `result.feasible?()` - Whether solution is feasible
    - `result.num_iterations` - Total iterations
    - `result.runtime` - Runtime in milliseconds
  - `{:error, reason}` - Failed to solve

  ## Example

      model = Model.new()
      |> Model.add_depot(x: 0, y: 0)
      |> Model.add_vehicle_type(num_available: 2, capacity: [100], time_windows: [{0, 28_800}])
      |> Model.add_client(x: 10, y: 0, delivery: [20])

      {:ok, result} = Solver.solve(model, max_iterations: 1000)
      IO.puts("Best distance: \#{result.best.distance}")

      # With a 60 second time limit
      {:ok, result} = Solver.solve(model, max_runtime: 60_000)

  """
  @dialyzer {:nowarn_function, solve: 1}
  @dialyzer {:nowarn_function, solve: 2}
  @spec solve(Model.t(), solve_opts()) :: {:ok, IteratedLocalSearch.Result.t()} | {:error, term()}
  def solve(%Model{} = model, opts \\ []) do
    solve_start = System.monotonic_time(:millisecond)
    opts = Keyword.merge(@default_opts, opts)

    base_seed = opts[:seed] || :rand.uniform(1_000_000)
    num_starts = resolve_num_starts(opts[:num_starts])

    with {:ok, problem_data} <- Model.to_problem_data(model) do
      problem_data_time = System.monotonic_time(:millisecond) - solve_start
      Logger.info("Problem data created in #{problem_data_time}ms")

      if num_starts == 1 do
        solve_single(problem_data, base_seed, opts, solve_start)
      else
        Logger.info("Starting #{num_starts} parallel solves")
        solve_parallel(problem_data, base_seed, num_starts, opts, solve_start)
      end
    end
  end

  defp solve_single(problem_data, seed, opts, solve_start) do
    stop_fn = build_stop_fn(opts)

    {local_search, penalty_manager, initial_origin, initial_solution} =
      setup_solver(problem_data, seed, opts, solve_start)

    notify_progress(opts[:on_progress], %{
      stage: :initial_solution,
      num_routes: length(Native.solution_routes(initial_solution)),
      total_duration: Native.solution_duration(initial_solution),
      num_clients: Native.solution_num_clients(initial_solution),
      is_feasible: Native.solution_is_feasible(initial_solution),
      best_distance: Native.solution_distance(initial_solution)
    })

    log_initial_solution(initial_origin, initial_solution, start_label(opts))

    total_setup_time = System.monotonic_time(:millisecond) - solve_start
    Logger.debug("Total setup time before ILS: #{total_setup_time}ms")

    result = run_ils(problem_data, penalty_manager, local_search, initial_solution, stop_fn, opts, seed, solve_start)

    ils_time = System.monotonic_time(:millisecond) - solve_start - total_setup_time
    total_time = System.monotonic_time(:millisecond) - solve_start
    Logger.info("#{start_label(opts)}ILS completed in #{ils_time}ms (#{result.num_iterations} iterations)")
    Logger.debug("Total solve time: #{total_time}ms (setup: #{total_setup_time}ms, ILS: #{ils_time}ms)")

    {:ok, result}
  end

  defp log_initial_solution(origin, solution, label) do
    solution
    |> Native.solution_is_feasible()
    |> initial_solution_state(origin)
    |> log_initial_feasibility(solution, label)
  end

  defp initial_solution_state(true, _origin), do: :feasible
  defp initial_solution_state(false, :repair_descent), do: :reported_by_repair
  defp initial_solution_state(false, _descended_from_empty), do: :infeasible_cold_start

  defp log_initial_feasibility(:reported_by_repair, _solution, _label), do: :ok

  defp log_initial_feasibility(:feasible, solution, label) do
    Logger.debug(
      "#{label}Initial solution is feasible: #{Native.solution_num_routes(solution)} route(s), " <>
        "#{Native.solution_num_clients(solution)} client(s)"
    )
  end

  defp log_initial_feasibility(:infeasible_cold_start, solution, label) do
    Logger.debug(
      "#{label}Initial solution is infeasible — #{describe_solution(solution)}. " <>
        "One descent from empty does not always reach feasibility; ILS continues from here."
    )
  end

  defp describe_solution(solution) do
    "#{Native.solution_num_routes(solution)} route(s), " <>
      "#{Native.solution_num_clients(solution)} client(s), " <>
      "#{initial_violations(solution)}"
  end

  defp initial_violations(solution) do
    [
      violation("time warp", sum_over_routes(solution, &Native.solution_route_time_warp/2), "s"),
      violation("excess load", sum_over_routes(solution, &route_excess_load/2), ""),
      violation("excess distance", sum_over_routes(solution, &Native.solution_route_excess_distance/2), ""),
      violation("same-vehicle groups split", Native.solution_num_same_vehicle_violations(solution), ""),
      client_group_violation(solution),
      complete_violation(Native.solution_is_complete(solution))
    ]
    |> Enum.reject(&is_nil/1)
    |> join_violations()
  end

  defp join_violations([]), do: "no violation reported"
  defp join_violations(violations), do: Enum.join(violations, ", ")

  defp violation(_label, 0, _unit), do: nil
  defp violation(label, amount, unit), do: "#{label} #{amount}#{unit}"

  defp client_group_violation(solution) do
    client_group_violated?(
      Native.solution_is_group_feasible(solution),
      Native.solution_num_same_vehicle_violations(solution)
    )
  end

  defp client_group_violated?(false, 0), do: "a client group violated"
  defp client_group_violated?(_group_feasible, _same_vehicle_violations), do: nil

  defp complete_violation(true), do: nil
  defp complete_violation(false), do: "required clients unvisited"

  defp route_excess_load(solution, route_idx) do
    solution
    |> Native.solution_route_excess_load(route_idx)
    |> Enum.sum()
  end

  defp sum_over_routes(solution, measure) do
    route_count = Native.solution_num_routes(solution)

    Enum.sum_by(0..(route_count - 1)//1, &measure.(solution, &1))
  end

  defp start_label(opts), do: format_label(opts[:log_label], opts[:start_index])

  defp format_label(nil, nil), do: ""
  defp format_label(nil, start_index), do: "[exvrp start #{start_index}] "
  defp format_label(log_label, nil), do: "[exvrp #{log_label}] "
  defp format_label(log_label, start_index), do: "[exvrp #{log_label} start #{start_index}] "

  defp solve_parallel(problem_data, base_seed, num_starts, opts, solve_start) do
    tasks =
      for idx <- 0..(num_starts - 1) do
        seed = base_seed + idx

        task_opts =
          opts
          |> augment_progress_callback(idx, seed)
          |> Keyword.put(:start_index, idx)

        Task.async(fn ->
          solve_single(problem_data, seed, task_opts, solve_start)
        end)
      end

    timeout = task_timeout(opts)
    results = Task.await_many(tasks, timeout)

    pick_best_result(results, num_starts, solve_start, opts)
  end

  defp pick_best_result(results, num_starts, solve_start, opts) do
    successes =
      results
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:ok, result}, start_index} -> [{result, start_index}]
        {{:error, _reason}, _start_index} -> []
      end)

    case successes do
      [] ->
        error =
          Enum.find_value(results, fn
            {:error, reason} -> reason
            {:ok, _result} -> nil
          end)

        {:error, error || :all_starts_failed}

      ok_results ->
        finalize_best(ok_results, num_starts, solve_start, opts)
    end
  end

  defp finalize_best(indexed_results, num_starts, solve_start, opts) do
    {best, best_index} = Enum.min_by(indexed_results, fn {result, _index} -> selection_key(result) end)

    total_runtime = System.monotonic_time(:millisecond) - solve_start
    total_iterations = Enum.sum_by(indexed_results, fn {result, _index} -> result.num_iterations end)
    log_label = opts[:log_label]

    Enum.each(indexed_results, fn {result, start_index} ->
      log_candidate(result, format_label(log_label, start_index))
    end)

    Logger.info(
      "#{format_label(log_label, nil)}Parallel solve complete: #{num_starts} starts, " <>
        "#{total_iterations} total iterations, best from start #{best_index}: " <>
        "cost #{IteratedLocalSearch.Result.cost(best)} (distance #{best.best.distance}, " <>
        "duration #{best.best.duration}, routes #{length(best.best.routes)})"
    )

    {:ok,
     %{
       best
       | runtime: total_runtime,
         stats: Map.merge(best.stats, %{num_starts: num_starts, total_iterations: total_iterations})
     }}
  end

  defp selection_key(result) do
    case IteratedLocalSearch.Result.cost(result) do
      :infinity -> {1, 0, 0}
      cost -> {0, cost, result.best.distance}
    end
  end

  defp log_candidate(%{best: best} = result, label) do
    Logger.info(
      "#{label}candidate: cost #{IteratedLocalSearch.Result.cost(result)}, " <>
        "distance #{best.distance}, duration #{best.duration}, routes #{length(best.routes)}, " <>
        "clients #{best.num_clients}, iterations #{result.num_iterations}"
    )
  end

  defp augment_progress_callback(opts, seed_idx, seed) do
    case opts[:on_progress] do
      callback when is_function(callback, 1) ->
        Keyword.put(opts, :on_progress, fn info ->
          callback.(Map.merge(info, %{seed_idx: seed_idx, seed: seed}))
        end)

      _other ->
        opts
    end
  end

  defp resolve_num_starts(:auto), do: max(div(System.schedulers_online(), 2), 1)
  defp resolve_num_starts(n) when is_integer(n) and n >= 1, do: n

  defp task_timeout(opts) do
    case opts[:max_runtime] do
      nil -> :infinity
      ms -> round(ms * 1.1) + 5_000
    end
  end

  defp setup_solver(problem_data, seed, opts, solve_start) do
    penalty_params = opts[:penalty_params] || %PenaltyManager.Params{}
    penalty_manager = PenaltyManager.init_from(problem_data, penalty_params)

    local_search_start = System.monotonic_time(:millisecond)
    local_search = Native.create_local_search(problem_data, seed)
    local_search_time = System.monotonic_time(:millisecond) - local_search_start
    Logger.debug("LocalSearch created (neighbours computed) in #{local_search_time}ms")

    {origin, initial_solution} =
      build_initial_solution(problem_data, local_search, penalty_manager, opts, solve_start)

    {local_search, penalty_manager, origin, initial_solution}
  end

  defp build_initial_solution(problem_data, local_search, penalty_manager, opts, solve_start) do
    initial_solution_start = System.monotonic_time(:millisecond)

    origin_and_solution =
      case typed_initial_routes(opts[:initial_routes]) do
        [] ->
          build_initial_via_local_search(problem_data, local_search, penalty_manager, opts, solve_start)

        typed_routes ->
          build_initial_from_routes_or_fallback(
            problem_data,
            local_search,
            penalty_manager,
            opts,
            solve_start,
            typed_routes
          )
      end

    initial_solution_time = System.monotonic_time(:millisecond) - initial_solution_start
    Logger.debug("Initial solution generated in #{initial_solution_time}ms")

    origin_and_solution
  end

  defp build_initial_from_routes_or_fallback(
         problem_data,
         local_search,
         penalty_manager,
         opts,
         solve_start,
         typed_routes
       ) do
    problem_data
    |> solution_from_typed_routes(typed_routes)
    |> start_from_routes_or_fallback(problem_data, local_search, penalty_manager, opts, solve_start)
  end

  defp solution_from_typed_routes(problem_data, typed_routes) do
    Native.create_solution_from_routes_with_types(problem_data, typed_routes)
  rescue
    e in [ArgumentError, RuntimeError] -> {:error, Exception.message(e)}
  end

  defp start_from_routes_or_fallback({:ok, sol}, problem_data, local_search, penalty_manager, opts, solve_start) do
    repair_if_infeasible(
      Native.solution_is_feasible(sol),
      sol,
      problem_data,
      local_search,
      penalty_manager,
      opts,
      solve_start
    )
  end

  defp start_from_routes_or_fallback({:error, message}, problem_data, local_search, penalty_manager, opts, solve_start) do
    Logger.warning("ExVrp.Solver: :initial_routes is invalid, falling back to empty start: #{message}")

    build_initial_via_local_search(problem_data, local_search, penalty_manager, opts, solve_start)
  end

  defp repair_if_infeasible(true, solution, _problem_data, _local_search, _penalty_manager, _opts, _solve_start),
    do: {:warm_start, solution}

  defp repair_if_infeasible(false, seed, problem_data, local_search, penalty_manager, opts, solve_start) do
    Logger.warning("#{start_label(opts)}Warm start is infeasible — #{initial_violations(seed)}; repairing it")

    kept =
      seed
      |> descend(local_search, penalty_manager, repair_budget_ms(opts, solve_start))
      |> keep_cheaper_of(seed, penalty_manager)
      |> drop_until_feasible(problem_data, opts, repair_budget_ms(opts, solve_start))

    log_repair(Native.solution_is_feasible(kept), kept, opts)

    {:repair_descent, kept}
  end

  defp keep_cheaper_of(repaired, seed, penalty_manager) do
    {:ok, max_cost_eval} = PenaltyManager.max_cost_evaluator(penalty_manager)

    cheaper_solution(
      Native.solution_penalised_cost(repaired, max_cost_eval) <= Native.solution_penalised_cost(seed, max_cost_eval),
      repaired,
      seed
    )
  end

  defp cheaper_solution(true, repaired, _seed), do: repaired
  defp cheaper_solution(false, _repaired, seed), do: seed

  # The descent minimises penalised cost, not violations. Every client carries a prize and every
  # violation only a finite penalty, so a descent can take on a client and the time warp that comes
  # with it. Where relocation is free it still lands on a feasible solution; where a same-vehicle
  # group forbids moving a client off its route, the only way to accept one is to overload the
  # route, and the seed can end further from feasibility than it started.
  #
  # Dropping visits is the one move that walks that back — but only for the violations a smaller
  # plan relieves. Feasibility also demands that every required client be visited and every required
  # client group be satisfied, and a removal only ever moves those the wrong way. So a removal is
  # taken only where it strictly improves the violation score, and the trimmed seed is kept only
  # where it came out feasible; otherwise the descent's own result stands.
  defp drop_until_feasible(solution, problem_data, opts, budget_ms) do
    drop_if_trimmable(trimmable?(solution), solution, problem_data, opts, budget_ms)
  end

  # What a trim cannot reach, it should not spend visits on: a seed already missing a required
  # client can never be completed by removing more of them. A seed carrying reload trips is fair
  # game. Each candidate is rebuilt from `Native.solution_trips/1` as a `{:trips, ...}` warm
  # start, so a multi-trip route keeps its reloads through the rebuild rather than collapsing into
  # a single load it was never sized for.
  defp trimmable?(solution), do: Native.solution_is_complete(solution)

  defp drop_if_trimmable(false, solution, _problem_data, _opts, _budget_ms), do: solution

  defp drop_if_trimmable(true, solution, problem_data, opts, budget_ms) do
    solution
    |> trim(problem_data, deadline(budget_ms), 0)
    |> keep_trim_if_feasible(solution, opts)
  end

  # Pricing every position of a route costs a rebuild per stop, so an unbounded trim can outlast the
  # run it is preparing. A run without a runtime cap reports no budget, and trims to completion.
  defp deadline(0), do: :infinity
  defp deadline(budget_ms), do: System.monotonic_time(:millisecond) + budget_ms

  defp within_deadline?(:infinity), do: true
  defp within_deadline?(deadline), do: System.monotonic_time(:millisecond) < deadline

  defp trim(solution, problem_data, deadline, dropped) do
    trim_further(worth_trimming?(solution, deadline, dropped), solution, problem_data, deadline, dropped)
  end

  defp worth_trimming?(solution, deadline, dropped) do
    not Native.solution_is_feasible(solution) and dropped < @max_repair_drops and within_deadline?(deadline)
  end

  defp trim_further(false, solution, _problem_data, _deadline, dropped), do: {solution, dropped}

  defp trim_further(true, solution, problem_data, deadline, dropped) do
    solution
    |> worst_route()
    |> best_removal(solution, problem_data)
    |> accept_removal(solution, problem_data, deadline, dropped)
  end

  defp accept_removal(:no_removal, solution, _problem_data, _deadline, dropped), do: {solution, dropped}

  defp accept_removal({:ok, trimmed}, solution, problem_data, deadline, dropped) do
    continue_from(
      violation_score(trimmed) < violation_score(solution),
      trimmed,
      solution,
      problem_data,
      deadline,
      dropped
    )
  end

  defp continue_from(false, _trimmed, solution, _problem_data, _deadline, dropped), do: {solution, dropped}

  defp continue_from(true, trimmed, _solution, problem_data, deadline, dropped) do
    trim(trimmed, problem_data, deadline, dropped + 1)
  end

  defp keep_trim_if_feasible({trimmed, dropped}, solution, opts) do
    trimmed_or_descended(Native.solution_is_feasible(trimmed), trimmed, solution, dropped, opts)
  end

  defp trimmed_or_descended(true, trimmed, _solution, dropped, opts) do
    log_drops(dropped, opts)

    trimmed
  end

  defp trimmed_or_descended(false, _trimmed, solution, _dropped, _opts), do: solution

  # Ordered by what a removal can and cannot undo. Missing required clients and unsatisfied client
  # groups come first because dropping only ever adds to them, so a candidate that trades real load
  # or time warp for one of those ranks worse and ends the trim instead of emptying the plan.
  defp violation_score(solution) do
    {
      rank_of(Native.solution_is_complete(solution)),
      rank_of(Native.solution_is_group_feasible(solution)),
      Native.solution_num_same_vehicle_violations(solution),
      sum_over_routes(solution, &route_excess_load/2),
      sum_over_routes(solution, &Native.solution_route_time_warp/2),
      sum_over_routes(solution, &Native.solution_route_excess_distance/2)
    }
  end

  # Ranked by the violations the route reports, then by length: the longest route is the best guess
  # when no route reports one of its own but the solution is still infeasible — a split group, say —
  # and it keeps the recursion making progress rather than picking the same empty-handed route
  # forever.
  defp worst_route(solution) do
    solution
    |> Native.solution_routes()
    |> Enum.with_index()
    |> Enum.reject(fn {visits, _idx} -> visits == [] end)
    |> Enum.max_by(fn {visits, idx} -> {route_violations(solution, idx), length(visits)} end, fn -> nil end)
  end

  defp route_violations(solution, route_idx) do
    {
      Native.solution_route_time_warp(solution, route_idx),
      route_excess_load(solution, route_idx),
      Native.solution_route_excess_distance(solution, route_idx)
    }
  end

  # Which visit to give up, measured rather than guessed. Time warp accrues from wherever a vehicle
  # first runs late, so the last visit of a late route is usually the one whose removal changes
  # least — dropping it repeatedly empties routes without repairing them. Pricing every position
  # and keeping the best costs one rebuild per stop of a single route and reaches feasibility in
  # the handful of drops the arithmetic actually calls for.
  defp best_removal(nil, _solution, _problem_data), do: :no_removal

  defp best_removal({visits, route_idx}, solution, problem_data) do
    typed = typed_routes(solution)

    0..(length(visits) - 1)//1
    |> Enum.map(&rebuild_without(typed, route_idx, &1, problem_data))
    |> Enum.filter(&match?({:ok, _candidate}, &1))
    |> least_violating()
  end

  defp rebuild_without(typed, route_idx, position, problem_data) do
    typed
    |> Enum.with_index()
    |> Enum.map(fn {{vehicle_type, trips}, idx} -> {vehicle_type, drop_at(idx == route_idx, trips, position)} end)
    |> Enum.reject(fn {_vehicle_type, trips} -> trips == [] end)
    |> Enum.map(fn {vehicle_type, trips} -> {vehicle_type, {:trips, as_warm_start(trips)}} end)
    |> then(&solution_from_typed_routes(problem_data, &1))
  end

  # `position` counts visits across the whole route, as `worst_route/1` sees it. A trip the removal
  # empties is a reload that carries nothing, so it goes too — and when that was the first trip,
  # the next one becomes first and leaves from the start depot instead.
  defp drop_at(true, trips, position) do
    trips
    |> drop_visit(position)
    |> Enum.reject(&(&1.clients == []))
  end

  defp drop_at(false, trips, _position), do: trips

  defp drop_visit([%{clients: clients} = trip | trips], position),
    do: drop_visit_from(position < length(clients), trip, trips, position)

  defp drop_visit_from(true, trip, trips, position),
    do: [%{trip | clients: List.delete_at(trip.clients, position)} | trips]

  defp drop_visit_from(false, trip, trips, position), do: [trip | drop_visit(trips, position - length(trip.clients))]

  defp as_warm_start([first | reloads]) do
    [
      %{reload_depot: nil, clients: first.clients}
      | Enum.map(reloads, &%{reload_depot: &1.start_depot, clients: &1.clients})
    ]
  end

  defp least_violating([]), do: :no_removal

  defp least_violating(candidates) do
    candidates
    |> Enum.map(fn {:ok, candidate} -> candidate end)
    |> Enum.min_by(&violation_score/1)
    |> then(&{:ok, &1})
  end

  defp rank_of(true), do: 0
  defp rank_of(false), do: 1

  # What the seed cost to make usable. The search is free to re-insert these wherever they fit, so
  # this is not the same as what the run ends up leaving unplanned — but a large number here is
  # the difference between "the day does not fit" and "we handed the search a wrecked plan".
  defp log_drops(0, _opts), do: :ok

  defp log_drops(dropped, opts) do
    Logger.info("#{start_label(opts)}Warm start repair dropped #{dropped} visit(s) to reach feasibility")
  end

  defp typed_routes(solution) do
    solution
    |> Native.solution_trips()
    |> Enum.with_index()
    |> Enum.map(fn {trips, idx} -> {Native.solution_route_vehicle_type(solution, idx), trips} end)
  end

  defp log_repair(true, _repaired, opts) do
    Logger.info("#{start_label(opts)}Warm start repaired to a feasible solution")
  end

  defp log_repair(false, repaired, opts) do
    Logger.warning("#{start_label(opts)}Warm start could not be repaired — #{initial_violations(repaired)}")
  end

  defp build_initial_via_local_search(problem_data, local_search, penalty_manager, opts, solve_start) do
    {:ok, empty_solution} = Native.create_solution_from_routes(problem_data, [])

    {:descent_from_empty,
     descend(empty_solution, local_search, penalty_manager, remaining_budget_ms(opts, solve_start))}
  end

  defp descend(solution, local_search, penalty_manager, budget_ms) do
    {:ok, max_cost_eval} = PenaltyManager.max_cost_evaluator(penalty_manager)

    {:ok, descended} = Native.local_search_search_run(local_search, solution, max_cost_eval, budget_ms)

    descended
  end

  defp repair_budget_ms(opts, solve_start) do
    opts
    |> remaining_budget_ms(solve_start)
    |> repair_share_of()
  end

  defp repair_share_of(0), do: 0
  defp repair_share_of(remaining_ms), do: max(round(remaining_ms * @repair_budget_share), 1)

  defp remaining_budget_ms(opts, solve_start) do
    opts
    |> resolve_max_runtime_ms()
    |> budget_left(solve_start)
  end

  defp budget_left(nil, _solve_start), do: 0

  defp budget_left(max_runtime_ms, solve_start) do
    max(round(max_runtime_ms) - (System.monotonic_time(:millisecond) - solve_start), 1)
  end

  defp typed_initial_routes(nil), do: []

  defp typed_initial_routes(routes) when is_list(routes) do
    routes
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {[], _idx} -> []
      {{:trips, trips}, idx} -> if all_trips_empty?(trips), do: [], else: [{idx, {:trips, trips}}]
      {clients, idx} when is_list(clients) -> [{idx, clients}]
    end)
  end

  # A `{:trips, [...]}` entry whose trips all carry zero clients is, as a warm start, the same
  # as an unused vehicle type: skip it exactly like a flat `[]` would be, rather than building an
  # empty route the NIF's Solution rejects. `match?/2` never raises, so a malformed trip (not a
  # map, or missing `:clients`) counts as non-empty here and is left for the NIF's own validation
  # to reject with its usual invalid-start warning. A `{:trips, ...}` whose value is not a list
  # goes the same way.
  defp all_trips_empty?(trips) when is_list(trips), do: Enum.all?(trips, &match?(%{clients: []}, &1))
  defp all_trips_empty?(_not_a_list), do: false

  defp run_ils(problem_data, penalty_manager, local_search, initial_solution, stop_fn, opts, seed, solve_start) do
    ils_params = opts[:ils_params] || %IteratedLocalSearch.Params{}

    Logger.debug("Starting ILS iterations")

    ils_opts = [seed: seed, on_progress: opts[:on_progress]]

    max_runtime_ms = resolve_max_runtime_ms(opts)

    ils_opts =
      if max_runtime_ms do
        setup_elapsed = System.monotonic_time(:millisecond) - solve_start
        remaining_ms = max(max_runtime_ms - setup_elapsed, 0)
        Keyword.put(ils_opts, :max_runtime_ms, remaining_ms)
      else
        ils_opts
      end

    IteratedLocalSearch.run(
      problem_data,
      penalty_manager,
      local_search,
      initial_solution,
      stop_fn,
      ils_params,
      ils_opts
    )
  end

  defp notify_progress(nil, _info), do: :ok
  defp notify_progress(callback, info) when is_function(callback, 1), do: callback.(info)
  defp notify_progress(_callback, _info), do: :ok

  # Extract max_runtime_ms from opts, checking both :max_runtime and :stop criteria.
  # This ensures the NIF gets per-iteration timeouts even when using stop: criteria.
  defp resolve_max_runtime_ms(opts) do
    cond do
      opts[:max_runtime] -> opts[:max_runtime]
      opts[:stop] -> extract_max_runtime_ms(opts[:stop])
      true -> nil
    end
  end

  defp extract_max_runtime_ms(%StoppingCriteria{type: :max_runtime, state: state}), do: state.max_ms

  defp extract_max_runtime_ms(%StoppingCriteria{type: type, state: %{criteria: criteria}})
       when type in [:multiple_criteria, :any, :all] do
    Enum.find_value(criteria, &extract_max_runtime_ms/1)
  end

  defp extract_max_runtime_ms(_criteria), do: nil

  # Build stop function from options
  defp build_stop_fn(opts) do
    criteria =
      cond do
        opts[:stop] != nil ->
          opts[:stop]

        opts[:max_runtime] != nil ->
          # max_runtime is in milliseconds, convert to seconds for StoppingCriteria
          StoppingCriteria.any([
            StoppingCriteria.max_iterations(opts[:max_iterations]),
            StoppingCriteria.max_runtime(opts[:max_runtime] / 1000.0)
          ])

        true ->
          StoppingCriteria.max_iterations(opts[:max_iterations])
      end

    StoppingCriteria.to_stop_fn(criteria)
  end
end

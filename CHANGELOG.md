# Changelog

## 0.11.0

### Fixed

- **Opening a new trip is priced in the objective's own currency.** `Solution::insert`'s
  multi-trip branch estimated a new trip as raw distance units plus reload cost minus the prize,
  then compared that against `insertCost()`'s exact penalised delta in cost units. The two are
  not the same unit, so whenever a unit of distance cost more than one the estimate understated
  and opening a new trip beat plain insertions that were genuinely cheaper. It now goes through
  a new exact `insertTripCost` primitive. Benchmark objectives are unchanged — the cost was
  search effort, not solution quality.

  `LocalSearch::improveWithMultiTrip` keeps its optimistic estimate on purpose; the comment
  there records why, and the measurement.

### Added

- `ExVrp.Native.insert_trip_cost_nif/6`, backing the `insertTripCost` primitive above and
  completing the set alongside `insert_cost_nif/4` and `remove_cost_nif/3`. It prices opening a
  new trip in a route — a reload depot inserted at an index, with the node directly after it —
  as an exact penalised delta, reload cost included.

- `ExVrp.Solution.num_same_vehicle_violations/1`, and the NIF behind it. `isGroupFeasible()` is
  one flag over two unrelated constraints — the mutually exclusive client groups a disjunctive
  time window expands into, and the same-vehicle groups that keep clients on one route — so a
  caller could not tell which broke. The count is zero exactly when the violated group was a
  client group.

- **An infeasible warm start is now reported and repaired rather than seeded silently.**
  `IteratedLocalSearch.run/7` takes the initial solution as its incumbent and only replaces it
  with something cheaper, so a seed that does not satisfy the model leaves the search with no
  feasible incumbent to fall back on — and nothing said so. `:initial_routes` producing an
  infeasible solution now runs the same local-search descent that a cold start uses, capped at a
  quarter of the remaining runtime, and logs the outcome with a violation breakdown (time warp,
  excess load, excess distance, split groups, unvisited required clients).

  **This is a partial repair.** The descent minimises penalised cost, not violations, so it can
  take on a client and the time warp that comes with it and end further from feasibility than it
  started. The seed is kept unless the repair is cheaper on penalised cost. A repair that only
  ever removes is the outstanding work.

## 0.10.0

The objective gains a third channel. Penalties are per-`(profile, location)` costs carried in
their own channel rather than smuggled through the distance matrix, which is what frees that
matrix to hold a real distance.

This release also carries everything that was tagged `v0.9.0` but never published. **There is
no 0.9.0 on Hex** — upgrading from 0.8.0 lands here, and the coordinate removal below is part
of that upgrade. Locations no longer carry coordinates, and the SwapStar operator is gone;
distance matrices are now the solver's only notion of distance, and a model must supply one.

### Removed

- **Breaking: `:x` and `:y` are removed from `add_client/2` and `add_depot/2`.** They fed
  exactly two things: a Euclidean distance matrix generated when a model supplied none, and
  SwapStar's centroid pruning. The second is gone (below), and the first is now an explicit
  call. To migrate, drop the coordinates and derive the matrices from them instead:

  ```elixir
  # before
  Model.new()
  |> Model.add_depot(x: 0, y: 0)
  |> Model.add_client(x: 10, y: 10, delivery: [20])

  # after
  Model.new()
  |> Model.add_depot([])
  |> Model.add_client(delivery: [20])
  |> Model.set_euclidean_matrices([{0, 0}, {10, 10}])
  ```

  Coordinates are in _location_ order — depots first, then clients — which is the order
  `ProblemData` indexes by, not necessarily the order you called the builders in. Callers
  that already supply their own matrices (via `set_distance_matrices/2`) just drop the
  coordinates; nothing else changes for them.

- **Breaking: `Route.centroid/1` and `Solution.route_centroid/2` are removed,** along with
  the `problem_data_centroid_nif`, `solution_route_centroid`, `search_route_centroid_nif`
  and `search_route_overlaps_with_nif` NIFs. Locations have no coordinates to average.

- **Breaking: the SwapStar operator is removed,** including `create_swap_star_nif/2`,
  `swap_star_evaluate_nif/4`, `swap_star_apply_nif/3`, and `:swap_star` in
  `local_search_with_operators`. It was measured on the full benchmark corpus (21 instances,
  4 seeds, 120s cap) against a no-SwapStar baseline: not one instance improved beyond its
  noise band, while iteration throughput fell 13% overall and 33-90% on the large instances.
  The two production prize-collecting instances got 5-17% worse.

  Its overlap tolerance was not the lever. `overlapsWith` pruned route pairs by the polar
  angle of their centroids, which degenerates when a caller feeds synthetic collinear
  coordinates. Re-running with tolerance 1.0 — every pair evaluated, a strict superset of
  what correct geometry would select — was worse still. What remains untested is a bounded
  per-pass timeout: the operator is O(V² × N) per pass and ran unbounded in every arm, which
  is where the throughput went.

  SwapStar was never in the default operator set, so this changes no solve. `bench.smoke`
  objectives are unchanged.

- **Internal: the pybind11 bindings are deleted** (`c_src/ex_vrp/bindings.{cpp,h}`,
  `c_src/ex_vrp/search/bindings.cpp`, ~1 900 lines). They were never in the Makefile, and
  they had stopped compiling: they include a `pyvrp_docs.h` this repo does not generate, and
  they read the `Client::x` / `Depot::x` members the coordinate removal deleted.

  With them gone, four C++ members lost their last caller and are removed too:
  `ProblemData::replace`, `ProblemData::VehicleType::replace`, and the "does no validation,
  useful when unserialising" constructors on `Route` and `Solution`, which existed for
  pybind's pickle support. The last had already drifted — it took `overtime` but not
  `reloadCost`, so it silently built a `Solution` with `reload_cost` zero. No Elixir surface
  changes.

  `c_src/svg_crash_test.cpp` is deleted for the same reason: no build target and broken by
  the coordinate removal. `c_src/solver_test.cpp` was broken the same way but is a live
  valgrind harness behind `make test-solver`, so it is repaired rather than removed.

### Added

- **`Model.set_penalties/2` sets per-profile, per-location penalties**, one list per routing
  profile holding one cost per location in matrix order — depots first, then clients:

  ```elixir
  # location 1 costs 500 extra to visit on profile 0
  Model.set_penalties(model, [[0, 500, 0]])
  ```

  A penalty is charged once for each visited location, so it is a per-client cost rather than
  a per-leg one, and it is invariant under reordering within a route. It is _soft_: a large
  enough prize outbids it.

  Depot entries must be zero, and a nonzero one is rejected when the model is solved. Exact
  route evaluation sums penalties over a trip's clients while local search sums them over
  every visit, depots included; requiring depots to be free is what keeps those two
  definitions equal. Use a depot's `reload_cost` to price a reload.

- **`Solution.penalty_cost/1` returns a solution's total penalty.** Penalties are a real
  objective term, not an infeasibility penalty, so they survive on a feasible solution and
  `cost/1` minus `penalty_cost/1` reads back as the plan's cost with penalties excluded.

- **`Model.set_forbidden/2` marks locations a profile may never visit**, one list of location
  indices per routing profile:

  ```elixir
  # vehicles on profile 1 may not visit location 1
  Model.set_forbidden(model, [[], [1]])
  ```

  This is the _hard_ counterpart to `set_penalties/2`. Local search prunes a forbidden
  location rather than costing it, so no prize reaches it — where a large penalty is merely
  expensive and a big enough prize outbids it. Zone restrictions a vehicle may breach at a
  cost want `set_penalties/2`; restrictions it physically cannot breach want this. Callers
  who want both should set both.

  Forbidding works whatever the profile count, including single-profile models. The insertion
  filter used to skip a model with one profile, on the reasoning that every client is then
  equally reachable — true while reachability was inferred from a distance sentinel, false
  once it became explicit. It now skips only when nothing is forbidden anywhere, which
  preserves the VRPB/backhaul behaviour that guard existed for while letting a single-profile
  model forbid something and mean it. A car-only fleet with uniform zone exemptions collapses
  to one profile, so this is an ordinary shape rather than a corner case.

  Indices must name clients: a vehicle starts and ends at its depot regardless, so forbidding a
  depot is rejected rather than quietly doing nothing.
  `Solution.num_forbidden_visits/1` reports violations, and is zero on any solution the solver
  produced.

- `Model.set_euclidean_matrices/2` sets both matrices to the rounded Euclidean distances
  between the given coordinates, taking durations to equal distances. This is the explicit
  replacement for the implicit generation that used to happen inside `to_problem_data/1`.

- **`add_same_vehicle_group/3` accepts client indices, not just structs**, and callers that
  know their indices should pass them:

  ```elixir
  # resolves by structural equality — ambiguous between identical clients
  Model.add_same_vehicle_group(model, [c2, c3])

  # says exactly which clients are meant
  Model.add_same_vehicle_group(model, [1, 2])
  ```

  Struct resolution still works and is unchanged. See the note under **Changed** for why it
  cannot be made unambiguous.

### Changed

- **The `1_000_000_000` distance sentinel is no longer a reachability contract.** Five sites
  in the search layer read a distance-matrix cell back and compared it against that hardcoded
  literal to decide whether a vehicle could reach a location, which made the caller's choice
  of "unreachable" magic number an undocumented part of the solver's interface. They now call
  `ProblemData::isAllowed`, backed by the per-profile set `set_forbidden/2` populates.

  Callers that encoded unreachability as a huge distance must move to `set_forbidden/2`. A
  huge distance still costs a lot, so such a model stays _roughly_ correct — but it loses
  pruning, so the search wastes time proposing moves it used to skip, and nothing reports it.

  This also unifies the five sites: `isHardToPlace` probed depot `0` for every profile while
  the other four used the profile's real start depot. The predicate has no depot in it.

- **Fixed: the route operators could move a client onto a profile that forbids it.**
  `applyRouteOps` had no reachability check, unlike `applyNodeOps`. `SwapTails` and
  `SwapRoutes` exchange clients between two routes wholesale, across profiles, so either
  could carry a restricted client onto a vehicle barred from it.

  This was latent rather than new. The distance sentinel enforced the constraint through the
  objective — such a move cost 1'000'000'000, so `deltaCost < 0` never held and the operator
  never fired. Once reachability is a predicate and the distance channel carries real
  distances, nothing was left to stop it. Route operators now refuse to exchange clients
  between two routes unless every client on each is allowed on the other's profile.

- **Fixed: the node operators only checked the two nodes they were named after.**
  `applyNodeOps` gated a cross-route move on `U` and `V` alone, but `Exchange<2, *>` carries
  `n(U)` along and `SwapTails` carries both whole tails, so a forbidden client could ride
  across as a passenger without ever being the node under consideration. Same latent-not-new
  story as the route operators above: the distance sentinel used to make such a move
  non-improving, and nothing replaced it.

  The operators now declare how many nodes they move — `spanU`/`spanV` on `NodeOperator`,
  alongside the existing `affectsEntireTail` — and the gate checks exactly those. Checking
  spans rather than conservatively barring the whole pair matters: `Exchange<N, 0>` does not
  move `V` at all, and refusing those moves would cost solution quality for nothing. The
  check is now per operator rather than per pair, so one barred operator no longer abandons
  moves the others could legally make.

- **Fixed: the in-place swap moves inserted without checking reachability.** Two sites in
  `applyOptionalClientMoves` and `insertConstrainedFirst` replace a client with another at
  the same position when that is cheaper. Both are insertions, and neither goes through
  `Solution::insert`, so neither was covered by its filter. Whether they fired depended on
  there being a cost incentive to swap, which the new penalty channel supplies.

- `Model.validate/1` now rejects a model with no distance matrix. Previously such a model
  silently got Euclidean distances derived from coordinates.

- **`Model.validate/1` now checks the penalty and forbidden shapes**, so a malformed one comes
  back as `{:error, messages}` from `solve/2` rather than as an exception out of the NIF, which
  is how every other shape check in the model already behaved. It checks list count against
  profile count, row length against location count, index range, and that depot penalties are
  zero. Two changes of behaviour follow: an out-of-range forbidden index used to be dropped in
  silence, which gave a caller who mis-indexed no restriction and no warning; and a _negative_
  penalty was accepted, which is load-bearing rather than cosmetic — `CostEvaluator`'s delta
  shortcut assumes a penalty can only raise a move's cost. The NIF decode stays defensive
  underneath, since `Native.create_problem_data/1` is reachable directly.

- **`Solution.num_forbidden_visits/1` reports visits a route's own profile forbids.** Zero on
  anything the solver produces; a nonzero value means a violation reached the objective
  unnoticed. It deliberately does _not_ enter `feasible?/1` — a violation carries no penalty
  gradient, so failing the solution would strand the search with no way to repair it. The
  sentinel used to provide this backstop by accident, because a violating route was ruinously
  expensive and so showed up in `cost/1`; making reachability a predicate removed that, and
  this replaces it as an explicit reporting channel. A debug assertion in `Route`'s constructor
  catches it under `SANITIZE=1`.

- **A forbidden index that cannot be honoured is now an error, not a silent drop.** Out-of-range
  indices used to be dropped during decode, and depot indices were accepted but never consulted.
  Both left a caller who asked for a restriction with no restriction and no warning. Both are
  rejected now, at both layers.

- Penalties are added to the delta cost alongside distance rather than after the pruning
  shortcuts, so the shortcuts see them. Leaving them until last held `out` below its true value
  and weakened every prune in proportion to how large the penalties were. Pruning was still
  sound — it could only ever under-prune — but it got worse the more the feature was used.

- Routes cache which profiles could take their clients wholesale, so the route-operator
  reachability check is two bit tests rather than a walk over both routes on every pair. The
  clearing pass only runs when the instance forbids something.

- **Fixed: `add_same_vehicle_group/3` resolved clients by structural equality,** so two
  clients with identical attributes both resolved to the first matching index and the group
  failed validation with "duplicate clients". Each match is now consumed once. Coordinates
  used to mask this by making otherwise-identical clients distinguishable.

  Consuming each match once fixes the validation failure but not the ambiguity underneath
  it, and the remaining half is quieter: resolution still starts from the first equal
  client, so asking for the _last_ two of three identical clients binds the first two
  instead. The group is well-formed and validates — it just constrains the wrong stops, and
  nothing reports it. Equality cannot express position, so no amount of care inside this
  function closes the gap; the information only exists at the call site. **Callers that
  hold indices must pass indices** (see **Added**). Callers whose clients are genuinely
  distinguishable are unaffected either way.

- The vendored PyVRP core moved from `c_src/pyvrp/` to `c_src/ex_vrp/`. The old path read as
  pristine upstream, but ~23 of its files carry local feature patches (same-vehicle groups,
  forbidden windows, reload/multi-trip, depot service-duration removal, NIF/ILS plumbing),
  so an upstream bump must be a three-way merge rather than an overwrite. The `pyvrp::`
  namespace and `PYVRP_*` header guards are deliberately unchanged — they are what keeps
  those merges tractable.

## 0.8.0

Overtime is reworked. `max_overtime` — an allowance bolted onto `shift_duration` — is replaced by an
explicit `max_duration` hard cap, and a new `overtime_start` adds clock-based overtime for drivers
who are contracted until a time of day rather than for a number of hours.

### Changed

- **Breaking: `max_overtime` is replaced by `max_duration`.** The old field was an allowance added to
  `shift_duration` to derive the hard cap; `max_duration` now _is_ the hard cap. To migrate, add the
  two numbers together:

  ```elixir
  # before
  Model.add_vehicle_type(model, shift_duration: 480, max_overtime: 60, unit_overtime_cost: 10)
  # after
  Model.add_vehicle_type(model, shift_duration: 480, max_duration: 540, unit_overtime_cost: 10)
  ```

  `max_duration` defaults to `shift_duration`, which matches the old `max_overtime: 0` default: a
  route may not run past its nominal shift. Vehicle types that never set `max_overtime` need no
  change. Note that this default makes `unit_overtime_cost` inert on its own — duration-based
  overtime is only reachable once `max_duration` is raised above `shift_duration`. `usage-rules.md`
  has a section on the three fields and how they interact.

- **Multi-trip construction now respects `max_duration` rather than `shift_duration`.** Both places
  that decide whether another trip fits — `LocalSearch`'s trip-insertion heuristic and the initial
  solution builder — capped the route at `shift_duration`, so raising `max_duration` bought a
  single-trip route more room but never a multi-trip one. Behaviour is unchanged for vehicle types
  that leave `max_duration` at its default, since that default is `shift_duration`.

- **Breaking: `ExVrp.Native.search_route_max_overtime_nif` is removed.** Use
  `search_route_max_duration_nif/1` for the hard cap or the new
  `search_route_overtime_start_nif/1` for the contracted end of shift.
  `search_route_max_duration_nif/1` is unchanged in name but now reports the value the caller
  passed rather than `shift_duration + max_overtime`.

- `ExVrp.solve/2` and `solve!/2` are specced as returning `ExVrp.IteratedLocalSearch.Result`, which
  is what they have always returned — the specs said `ExVrp.Solution` and were silenced with
  `@dialyzer {:nowarn_function, ...}`. The specs are now correct and the suppressions are gone;
  dialyzer passes without them.

### Documented

- **`shift_duration` and `max_duration` both measure elapsed time, not time worked.** Route duration
  runs from route start to route end with idle time included, so neither field expresses "no more
  than N hours worked per day": a day of two short shifts separated by a long gap breaches an
  elapsed cap the driver's actual hours would clear. Concretely, a route with 300 units of driving
  spread across a 900-unit day is infeasible under `max_duration: 500`. `usage-rules.md` and the
  `ProblemData` docs now say so, and point at `Route.duration/1 - Route.wait_duration/1` for
  measuring worked time after the fact. No behaviour change — this was always true and undocumented.

### Added

- **`overtime_start`** on `ExVrp.VehicleType` — the contracted end of shift, on the same axis as
  `:time_windows`. When set, overtime becomes `max(0, route_end - overtime_start)`: a driver
  contracted until 16:00 who runs 09:00–17:00 has worked an hour of overtime even though the route
  lasted only the nominal eight. Defaults to `:infinity`, in which case overtime stays
  `max(0, duration - shift_duration)` as before.

- `ExVrp.Native.search_route_overtime_start_nif/1`, completing the search-route accessor set
  alongside `search_route_shift_duration_nif/1` and `search_route_max_duration_nif/1`.

- Doctests for `ExVrp` itself, so the moduledoc's end-to-end example is executed rather than
  asserted. The example's stated result was wrong (`[[1, 2], [3]]` at distance 8944 for an instance
  whose optimum is a single route at 68); it now shows real output, and notes that route entries are
  location indices.

### Fixed

- **Local search was blind to overtime cost whenever the hard cap was unbounded.**
  `Route::hasDurationCost` gates whether `CostEvaluator::deltaCost` prices the duration and
  time-warp terms of a move at all. It tested the old `max_overtime != 0`, whose natural translation
  (`overtime_start` being set) drops the duration-based case: with `shift_duration: 480,
max_duration: :infinity, unit_overtime_cost: 10` it returned `false`, so every move on that route
  was evaluated as if overtime were free. It now also accounts for a finite `shift_duration`.

- **Search-side overtime was wrong when forbidden windows were in play.** The search route derived
  its end time as `start + duration - time_warp`, but under forbidden windows `time_warp` carries
  violation penalties that are not shifts along the timeline. A route with `overtime_start: 250` and
  a forbidden window it had to idle through reported 0 overtime in the search where the final route
  reported 250. The search now uses the end time from the schedule walk it already performs, and the
  two agree.

## 0.7.1

### Added

- `usage-rules.md`, consumed by [usage_rules](https://hexdocs.pm/usage_rules), so agents working in
  a consuming project get ExVrp's semantics at request time instead of inferring them. It documents
  the traps that are invisible from the type specs: location indices being offset by the depot
  count, capacity dimensions having to match the first vehicle type, `:time_windows` being the only
  accepted way to give a vehicle its hours, `required: false` meaning nothing without a prize, and
  `IteratedLocalSearch.Result.cost/1` being an objective rather than a distance.
- `CHANGELOG.md` and `usage-rules.md` are now shipped in the package and rendered in the docs — the
  package included neither before.
- `usage-rules.md` also covers the cost model (`unit_distance_cost`, `unit_duration_cost`,
  `fixed_cost`, and the fact that duration is free by default and dwarfs distance once service times
  are counted), warm-starting via `:initial_routes`, multi-trip via `reload_depots`, and `:log_label`.
- **Doctests.** The project had none, so every `iex>` example in the moduledocs was unverified —
  which is how two fabricated result values survived in the docs. `ExVrp.Client`, `ExVrp.ClientGroup`,
  `ExVrp.Depot`, `ExVrp.NeighbourhoodParams`, `ExVrp.PerturbationManager` and `ExVrp.VehicleType` are
  now executed as doctests (13 in total). Examples that used elided `...` output were reshaped into
  runnable form rather than deleted.

### Fixed

- **`Solver.solve/2`'s `:max_runtime` was documented as seconds.** It has always been milliseconds —
  `resolve_max_runtime_ms/1` passes the value straight through — so the docstring's
  `max_runtime: 60.0` example asked for a 60 millisecond solve. `ExVrp.solve/2` already documented it
  correctly; the two now agree, and both point at `StoppingCriteria.max_runtime/1` being the one that
  takes seconds.

- **README quick start printed results the code does not produce.** It claimed
  `routes #=> [[1, 2], [3]]` and `distance #=> 8944`; the actual output is `[[2, 1, 3]]` and `68`.
  The install snippet still pinned `~> 0.4.0`, and the prerequisites said Elixir 1.15+ against
  `elixir: "~> 1.18"` in `mix.exs`. The development section now also documents `EX_VRP_FORCE_BUILD=1`,
  without which `c_src/` edits are silently ignored in favour of a precompiled artifact.

- **Flaky timing tests made load-independent.** `ExVrp.TimeoutTest`, `ExVrp.SolveTest`,
  `ExVrp.OscillationPreventionTest` and `ExVrp.PrizeCollectingEdgeCasesTest` all asserted on elapsed
  time, so `mix check` failed intermittently: running ex_unit alongside dialyzer, credo and reach
  starves the schedulers, and a 250ms budget reported 892ms while a 1.5s oscillation guard took
  3734ms. `TimeoutTest` had also assumed `result.runtime` was not a wall-clock measurement; it is,
  just taken inside the ILS loop.

  The oscillation tests were measuring the wrong thing entirely. Those searches complete their full
  iteration budget in 10-29ms; oscillation manifests as a search stalling inside an iteration and
  being cut off by `max_runtime` after a handful, not as a slow wall clock. They now assert that the
  iteration budget was completed, which is immune to machine load. The timeout tests assert that the
  stopping criterion _fired_ — the run ended well short of the default 10_000 iterations — and keep
  only a loose runtime ceiling to catch a criterion that is ignored outright. All timing-sensitive
  solves also pin `num_starts: 1` so one chain's budget is what is being measured.

  `SolveTest` additionally passed `max_runtime: 0.001`, a float left over from the seconds
  assumption, where `solve_opts` declares `pos_integer()`.

### Changed

- The `ExVrp.ABBenchmark.*` modules live under `dev/` and are not shipped in the package, but were
  still published to HexDocs. They are now filtered out, which also clears the `mix docs` warnings
  about their hidden types.

### Known issues

- `ExVrp.Route`'s `trips` field is declared on the struct and in its typespec, but
  `ExVrp.Solution.routes/1` never populates it — it is always `[]`, even on a route that made three
  trips. Use `ExVrp.Route.num_trips/1`. Documented in `usage-rules.md`; populating the field is a
  behavioural change left for a later release.

## 0.7.0

### Fixed

- **`solve/2` with `num_starts > 1` picked the winning start on the wrong metric.**
  `IteratedLocalSearch.Result.cost/1` returned `best.distance`, while every ILS chain
  minimises `unit_distance_cost × distance + unit_duration_cost × duration +
fixed_cost × vehicles + uncollected prizes`. `Solver.finalize_best/3` ranks starts
  with that function, so the cross-start winner was chosen on one term of an
  objective no start had optimised. It now returns the full objective
  (`stats.final_cost`), still `:infinity` when infeasible.

  This is a **behavioural change for callers reading `Result.cost/1` as a distance** —
  it now equals distance only when `unit_duration_cost` is 0, no vehicle type sets a
  `fixed_cost`, and every client is visited. Measured on a 153-order instance with a
  fixed vehicle cost: the old rule returned a 7-vehicle plan, the new rule a
  6-vehicle plan that was also shorter in duration.

### Changed

- **`IteratedLocalSearch.Params` default `max_no_improvement` lowered from `50_000`
  to `800`.** Upstream PyVRP's `150_000` assumes runs of millions of iterations; a
  two-minute solve of ~150 locations runs about 10_000, so any threshold in that
  range left `maybe_restart/1` unreachable and a stalled chain simply burned its
  remaining budget. On the same instance `800` fires 3-6 restarts per start and
  raises total iterations ~29%. Pass `ils_params` to override.

- Per-iteration and per-start setup logging dropped from `:info` to `:debug`
  (`ILS iteration`, `LocalSearch created`, `Initial solution generated`,
  `Total setup time before ILS`, `Total solve time`). An 8-start two-minute solve
  emitted over a thousand `:info` lines, burying everything else in the host's log.

### Added

- Parallel solves log one `[exvrp start N] candidate:` line per finished start
  (cost, distance, duration, routes, clients, iterations), and
  `Parallel solve complete` names the winning start. `ILS completed` is prefixed
  with `[exvrp start N]` so interleaved chains can be told apart. Indices are the
  original spawn indices and stay stable when a start fails.

- **New `:log_label` option on `solve/2`.** Start indices only tell chains apart
  _within_ one solve, so a host running several solves concurrently would see the
  same `[exvrp start 0..3]` labels from all of them. `log_label: "relaxed_15"`
  namespaces every line of that solve:

      [exvrp relaxed_15 start 2] ILS completed in 4210ms (3180 iterations)
      [exvrp relaxed_15 start 2] candidate: cost 977440, distance 252435, ...
      [exvrp relaxed_15] Parallel solve complete: 4 starts, ... best from start 2: ...

  Defaults to `nil`, which keeps the unlabelled format.

## 0.6.0

### Added

- **Exhaustive-on-best polishing in Iterated Local Search (PyVRP #988).** When a
  candidate becomes a new global best, it is now polished with a non-perturbing
  (exhaustive) local-search pass before being recorded as the best. Controlled by
  the new `exhaustive_on_best` field on `IteratedLocalSearch.Params` (default
  `true`). The polished result replaces the candidate only when it is feasible;
  an infeasible polish falls back to the original candidate.

- New `exhaustive` argument on `Native.local_search_run/5` (default `false`),
  backing the polishing pass. Passing `true` skips perturbation and runs a pure
  intensification search, matching PyVRP's `exhaustive` flag.

### Changed

- `IteratedLocalSearch.Params` default `max_no_improvement` restored from an
  accidental `5_000` to `50_000` (upstream PyVRP uses `150_000`).

- **NIF `local_search_run_nif` arity changed from 4 to 5.** This bumps the
  minor version because the precompiled artifact is version-pinned: consumers
  must pull the `v0.6.0` release binary (or force a local build with
  `EX_VRP_FORCE_BUILD=1`) — the `v0.5.x` artifact exposes the old arity-4 NIF
  and will fail to load against this release.

## 0.5.3

### Added

- **Warm-start solver via `:initial_routes` option on `ExVrp.solve/2`.** The
  outer list position maps to the vehicle type index; each inner list is the
  sequence of client IDs visited by that vehicle type. Empty inner lists are
  skipped. Example:

  ```elixir
  ExVrp.solve(model, initial_routes: [[1, 2, 3], [], [4, 5]])
  # vehicle type 0 → clients 1, 2, 3; vehicle type 2 → clients 4, 5
  ```

  Use this when you already have a known-good (or even partially-known)
  assignment to seed the solver — e.g. inserting new orders into existing
  routes — instead of cold-starting from an empty solution.

- New `Native.create_solution_from_routes_with_types/2` NIF backing the
  warm-start path. Takes `[{vehicle_type, [client_id, ...]}, ...]`, unlike the
  existing `create_solution_from_routes/2` which hardcodes vehicle type 0 and
  is only suitable for homogeneous fleets.

### Robustness

- Warm-start inputs are bounds-checked in the NIF before constructing the
  C++ `Solution`: vehicle type indices outside `[0, numVehicleTypes())` and
  client IDs outside `[numDepots, numLocations)` now raise `ArgumentError`
  with a descriptive message instead of segfaulting.
- `ExVrp.solve/2` rescues any `ArgumentError`/`RuntimeError` from the
  warm-start NIF and falls back to an empty-solution start with a warning
  log. Structurally invalid `:initial_routes` (duplicate clients, malformed
  tuples, too many routes for `num_available`) no longer crash the solve.
- Capacity-overloaded or time-window-violating warm-starts are passed through
  to the solver unchanged — these are valid infeasible starting points that
  the solver can repair via penalties.

## 0.5.2

### Internal

- Static analysis baseline: zero findings across credo, sobelow, ex_dna, and
  reach (arch/dead-code/smells/candidates). Wired into `mix check` and the
  pre-commit hook; PRs also run `mix reach.check --changed`.
- Performance: hot validators in `Model` and `Read` switched from
  `Enum.at`-in-loop and length checks to `Stream.with_index`, `Enum.sum_by`,
  `List.to_tuple` + `elem/2`, and `Enum.zip_with`.
- Architecture: `ExVrp.Native` is now a true PDG leaf (type-erased
  `Model.t()` in the @spec) with explicit reach forbidden rules.
- Safety: replaced `String.to_atom/1` in TSPLIB parsing with
  `String.to_existing_atom/1` + rescue.

## 0.5.1

### Added

- Forbidden time windows in route planning: support for multiple disjunctive
  feasibility windows on vehicle time, used by the local search to evaluate
  insertions against reload-time constraints (see `test/forbidden_window_test.exs`).

### Fixed

- AddressSanitizer / Valgrind setup stabilised across the C++ search code
  (`LocalSearch`, `Route`, `Solution`, `CostEvaluator`).

### Internal

- Removed the in-tree `credo/append_in_loop.ex` custom check (and its test);
  superseded by upstream tooling.

## 0.5.0

### Breaking Changes

- **VehicleType: replaced `tw_early`/`tw_late`/`forbidden_windows` with `time_windows`**

  The `VehicleType` API now uses a single `:time_windows` option (list of `{start, end}` tuples)
  instead of separate `:tw_early`, `:tw_late`, and `:forbidden_windows` options.

  ```elixir
  # Before
  Model.add_vehicle_type(model,
    num_available: 1,
    capacity: [100],
    tw_early: 0,
    tw_late: 28_800
  )

  # After
  Model.add_vehicle_type(model,
    num_available: 1,
    capacity: [100],
    time_windows: [{0, 28_800}]
  )
  ```

  Multiple disjunctive time windows are now first-class:

  ```elixir
  Model.add_vehicle_type(model,
    num_available: 1,
    capacity: [100],
    time_windows: [{0, 500}, {600, 1000}]
  )
  ```

  When `:time_windows` is omitted, it defaults to `[{0, :infinity}]` (no time constraint).

  Passing `:tw_early`, `:tw_late`, or `:forbidden_windows` directly now raises an
  `ArgumentError` with a migration hint.

- **Invalid time windows are silently filtered** instead of raising. Windows where
  `start >= end` are dropped. If all windows are invalid, the vehicle gets
  `tw_early: 0, tw_late: 0` (effectively unusable).

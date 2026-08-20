# Changelog

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

- **Breaking: `ExVrp.Native.search_route_max_overtime_nif/1` is removed.** Use
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

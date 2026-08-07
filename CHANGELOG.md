# Changelog

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

# Changelog

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

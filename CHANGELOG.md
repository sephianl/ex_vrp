# Changelog

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

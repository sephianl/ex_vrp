# Changelog

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

---
name: exvrp-reference
description: Complete reference for ExVRP — architecture, model building, solver internals, NIF bindings, data structures, and testing. Use when working on any ExVRP feature, debugging solver issues, adding new constraints, or understanding the PyVRP port.
---

# ExVRP Reference

Elixir bindings for [PyVRP](https://github.com/PyVRP/PyVRP). Direct port of the Python API using the same C++ core via NIFs (Fine library).

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Public API                                              │
│   ExVrp.solve/2, ExVrp.solve!/2                        │
├─────────────────────────────────────────────────────────┤
│ Model Building                                          │
│   Model, Client, Depot, VehicleType, ClientGroup,       │
│   SameVehicleGroup                                      │
├─────────────────────────────────────────────────────────┤
│ Solver Pipeline                                         │
│   Solver -> PenaltyManager -> IteratedLocalSearch       │
│   StoppingCriteria, Statistics                          │
├─────────────────────────────────────────────────────────┤
│ Solution Inspection                                     │
│   Solution, Route, ScheduledVisit, Trip                 │
├─────────────────────────────────────────────────────────┤
│ Utilities                                               │
│   Read (VRPLIB parser), Neighbourhood (Nx proximity),   │
│   MinimiseFleet, Benchmark                              │
├─────────────────────────────────────────────────────────┤
│ NIF Layer                                               │
│   ExVrp.Native (Fine bindings) -> c_src/ex_vrp_nif.cpp  │
│   c_src/pyvrp/ (PyVRP C++ core)                        │
└─────────────────────────────────────────────────────────┘
```

## Module Map

| Module                      | File                                  | Purpose                                              |
| --------------------------- | ------------------------------------- | ---------------------------------------------------- |
| `ExVrp`                     | `lib/ex_vrp.ex`                       | Top-level `solve/2`, `solve!/2`                      |
| `ExVrp.Model`               | `lib/ex_vrp/model.ex`                 | Problem builder (fluent API)                         |
| `ExVrp.Client`              | `lib/ex_vrp/client.ex`                | Client struct (coords, demands, time windows, prize) |
| `ExVrp.Depot`               | `lib/ex_vrp/depot.ex`                 | Depot struct (coords, time windows, reload cost)     |
| `ExVrp.VehicleType`         | `lib/ex_vrp/vehicle_type.ex`          | Fleet definition (capacity, costs, depots, profile)  |
| `ExVrp.ClientGroup`         | `lib/ex_vrp/client_group.ex`          | Mutually exclusive / required groups                 |
| `ExVrp.SameVehicleGroup`    | `lib/ex_vrp/same_vehicle_group.ex`    | Same-vehicle constraints                             |
| `ExVrp.Solver`              | `lib/ex_vrp/solver.ex`                | Main solve orchestration                             |
| `ExVrp.IslandSolver`        | `lib/ex_vrp/island_solver.ex`         | Parallel ILS with BEAM-process islands               |
| `ExVrp.IteratedLocalSearch` | `lib/ex_vrp/iterated_local_search.ex` | ILS + Late Acceptance Hill-Climbing                  |
| `ExVrp.PenaltyManager`      | `lib/ex_vrp/penalty_manager.ex`       | Dynamic penalty adjustment (target 65% feasibility)  |
| `ExVrp.StoppingCriteria`    | `lib/ex_vrp/stopping_criteria.ex`     | Composable stop conditions                           |
| `ExVrp.Solution`            | `lib/ex_vrp/solution.ex`              | Solution struct + route query methods                |
| `ExVrp.Route`               | `lib/ex_vrp/route.ex`                 | Per-route queries (distance, duration, feasibility)  |
| `ExVrp.ScheduledVisit`      | `lib/ex_vrp/scheduled_visit.ex`       | Visit timing (service start/end, wait, time warp)    |
| `ExVrp.Trip`                | `lib/ex_vrp/trip.ex`                  | Trip within a multi-trip route                       |
| `ExVrp.Neighbourhood`       | `lib/ex_vrp/neighbourhood.ex`         | Granular neighbourhood via Nx tensors                |
| `ExVrp.NeighbourhoodParams` | `lib/ex_vrp/neighbourhood_params.ex`  | Neighbourhood configuration                          |
| `ExVrp.PerturbationManager` | `lib/ex_vrp/perturbation_manager.ex`  | Random perturbation during local search              |
| `ExVrp.MinimiseFleet`       | `lib/ex_vrp/minimise_fleet.ex`        | Binary search for minimum fleet size                 |
| `ExVrp.Read`                | `lib/ex_vrp/read.ex`                  | VRPLIB instance file parser                          |
| `ExVrp.Statistics`          | `lib/ex_vrp/statistics.ex`            | Search trajectory tracking + CSV export              |
| `ExVrp.Native`              | `lib/ex_vrp/native.ex`                | NIF bindings (Fine)                                  |

## Solve Pipeline

```
ExVrp.solve(model, opts)
  -> Solver.solve/2
      1. Parse options (merge defaults, build stop_fn early for max_runtime)
      2. Model.to_problem_data(model) -> NIF: create_problem_data
      3. PenaltyManager.init_from(problem_data) -> initial penalties from cost structure
      4. Native.create_local_search(problem_data, seed) -> persistent LS resource
      5. Create initial solution:
         a. Native.create_solution_from_routes(problem_data, [])  (empty)
         b. Native.local_search_search_run(ls, empty, max_cost_eval, timeout)
      6. IteratedLocalSearch.run(problem_data, pm, ls, init_sol, stop_fn, params, opts)
      7. Return {:ok, %Result{best: %Solution{}, stats, num_iterations, runtime}}
```

### ILS Inner Loop

Each iteration:

1. **maybe_restart** — if `iters_no_improvement >= max_no_improvement` (default 50,000): reset to best, clear history
2. **search_step** — `Native.local_search_run(ls, current, cost_eval, timeout_ms)` -> candidate
3. **accept_step** — Late Acceptance Hill-Climbing:
   - Update best if `candidate_cost < best_cost` (using `cost()` — infeasible = `:infinity`)
   - Accept if `cand_cost < late_cost OR cand_cost < curr_cost` (using `penalised_cost()`)
   - Update ring buffer history
4. **update_penalty_manager** — register solution, adjust penalties if threshold reached
5. **maybe_report_progress** — fire `on_progress` callback every ~1s

### Cost Functions

- `solution_cost(ref, eval)` — objective cost; returns `:infinity` for infeasible (used for best selection + stopping)
- `solution_penalised_cost(ref, eval)` — includes penalty terms (used for LAHC acceptance)

## Model Building API

### Creating a Model

```elixir
model =
  Model.new()
  |> Model.add_depot(x: 0, y: 0)
  |> Model.add_depot(x: 100, y: 0, tw_early: 0, tw_late: 28800)  # end depot
  |> Model.add_vehicle_type(
    num_available: 3,
    capacity: [100, 50],           # multi-dimensional
    start_depot: 0,
    end_depot: 1,
    tw_early: 0,
    tw_late: 28800,
    shift_duration: 28800,         # max shift (seconds)
    max_distance: :infinity,
    unit_distance_cost: 1,
    unit_duration_cost: 0,
    profile: 0,                    # which distance/duration matrix to use
    fixed_cost: 0,
    reload_depots: [0],            # for multi-trip
    max_reloads: :infinity
  )
  |> Model.add_client(
    x: 10, y: 20,
    delivery: [25, 5],             # per capacity dimension
    pickup: [0, 0],
    service_duration: 300,
    tw_early: 0,
    tw_late: 14400,
    release_time: 0,
    prize: 0,                      # >0 makes client optional
    required: true
  )
```

### Client Groups (Mutually Exclusive)

```elixir
{model, group} = Model.add_client_group(model, required: false)
# required: false -> mutually_exclusive: true (at most one visited)
# required: true, mutually_exclusive: true -> exactly one visited (GTSP)
model = Model.add_client(model, x: 1, y: 1, group: group)
model = Model.add_client(model, x: 2, y: 2, group: group)
```

### Same-Vehicle Groups

```elixir
[c1, c2] = model.clients
model = Model.add_same_vehicle_group(model, [c1, c2], name: "equipment")
```

### Custom Matrices

```elixir
model
|> Model.set_distance_matrices([matrix_profile_0, matrix_profile_1])
|> Model.set_duration_matrices([matrix_profile_0, matrix_profile_1])
```

If not set, Euclidean distances from coordinates are used. One matrix per profile index.

### Validation

`Model.validate/1` checks: depots exist, vehicle types exist, capacity dimension consistency, time windows (tw_late >= tw_early), non-negative service/demands, depot indices valid, matrix dimensions, diagonal zeros, group validity.

## Data Structures

### Client

| Field            | Type              | Default   | Notes                                          |
| ---------------- | ----------------- | --------- | ---------------------------------------------- |
| x, y             | number            | required  | Coordinates                                    |
| delivery         | [non_neg_integer] | [0]       | Per capacity dimension                         |
| pickup           | [non_neg_integer] | [0]       | Per capacity dimension                         |
| service_duration | non_neg_integer   | 0         | Seconds                                        |
| tw_early         | non_neg_integer   | 0         | Time window start                              |
| tw_late          | non_neg_integer   | :infinity | Time window end; :infinity -> INT64_MAX in C++ |
| release_time     | non_neg_integer   | 0         | Earliest availability                          |
| prize            | non_neg_integer   | 0         | Prize-collecting: >0 makes optional            |
| required         | boolean           | true      | Must be visited?                               |
| group            | integer \| nil    | nil       | ClientGroup index                              |

### VehicleType

| Field                  | Type              | Default      | Notes                    |
| ---------------------- | ----------------- | ------------ | ------------------------ |
| num_available          | pos_integer       | required     | Fleet size of this type  |
| capacity               | [non_neg_integer] | required     | Per dimension            |
| start_depot, end_depot | non_neg_integer   | 0            | Depot indices            |
| fixed_cost             | non_neg_integer   | 0            | Per vehicle used         |
| tw_early, tw_late      | non_neg_integer   | 0, :infinity | Operating window         |
| shift_duration         | non_neg_integer   | :infinity    | Max route duration       |
| max_distance           | non_neg_integer   | :infinity    | Max route distance       |
| unit_distance_cost     | non_neg_integer   | 1            | Cost per distance unit   |
| unit_duration_cost     | non_neg_integer   | 0            | Cost per time unit       |
| profile                | non_neg_integer   | 0            | Matrix profile index     |
| start_late             | non_neg_integer   | 0            | Latest start time        |
| max_overtime           | non_neg_integer   | 0            | Allowed overtime         |
| unit_overtime_cost     | non_neg_integer   | 0            | Cost per overtime unit   |
| reload_depots          | [non_neg_integer] | []           | Multi-trip reload points |
| max_reloads            | non_neg_integer   | :infinity    | Max reloads per route    |
| initial_load           | [non_neg_integer] | []           | Starting load            |

### Depot

| Field             | Type            | Default      | Notes                 |
| ----------------- | --------------- | ------------ | --------------------- |
| x, y              | number          | required     | Coordinates           |
| tw_early, tw_late | non_neg_integer | 0, :infinity | Operating window      |
| service_duration  | non_neg_integer | 0            | Reload time           |
| reload_cost       | non_neg_integer | 0            | Cost per reload visit |

### Solution

| Field        | Type                | Notes                        |
| ------------ | ------------------- | ---------------------------- |
| routes       | [[non_neg_integer]] | Client indices per route     |
| distance     | non_neg_integer     | Total distance               |
| duration     | non_neg_integer     | Total duration               |
| num_clients  | non_neg_integer     | Assigned clients             |
| is_feasible  | boolean             | All constraints satisfied    |
| is_complete  | boolean             | All required clients visited |
| solution_ref | reference           | NIF resource for queries     |
| problem_data | reference           | NIF resource                 |

### ScheduledVisit

| Field         | Type            | Notes                                 |
| ------------- | --------------- | ------------------------------------- |
| location      | non_neg_integer | Location index                        |
| trip          | non_neg_integer | Trip index (multi-trip)               |
| start_service | non_neg_integer | Service start time                    |
| end_service   | non_neg_integer | Service end time                      |
| wait_duration | non_neg_integer | Waiting before service                |
| time_warp     | non_neg_integer | Late arrival amount (>0 = infeasible) |

## Solution Inspection API

### Solution-level

```elixir
Solution.feasible?(sol)          # all constraints satisfied?
Solution.complete?(sol)          # all required clients visited?
Solution.group_feasible?(sol)    # same-vehicle constraints ok?
Solution.distance(sol)           # total distance
Solution.duration(sol)           # total duration
Solution.cost(sol)               # distance (default cost)
Solution.cost(sol, cost_eval)    # cost with evaluator (:infinity if infeasible)
Solution.num_routes(sol)
Solution.num_clients(sol)
Solution.unassigned(sol)         # list of unassigned client indices
Solution.time_warp(sol)          # total across routes
Solution.excess_load(sol)        # [per dimension]
Solution.excess_distance(sol)
Solution.overtime(sol)
Solution.fixed_vehicle_cost(sol)
Solution.distance_cost(sol)
Solution.duration_cost(sol)
Solution.reload_cost(sol)
```

### Route-level (via Solution or Route struct)

```elixir
# Via Solution
Solution.route(sol, idx)         # -> %Route{} with solution_ref set
Solution.routes(sol)             # -> [%Route{}]
Solution.route_schedule(sol, idx) # -> [%ScheduledVisit{}]
Solution.route_distance(sol, idx)
Solution.route_vehicle_type(sol, idx)
Solution.route_start_time(sol, idx)
Solution.route_end_time(sol, idx)

# Via Route struct (requires solution_ref)
Route.distance(route)
Route.duration(route)
Route.feasible?(route)
Route.delivery(route)            # [per dimension]
Route.pickup(route)
Route.excess_load(route)
Route.time_warp(route)
Route.overtime(route)
Route.start_time(route)
Route.end_time(route)
Route.slack(route)
Route.service_duration(route)
Route.travel_duration(route)
Route.wait_duration(route)
Route.visits(route)              # client indices
Route.schedule(route)            # raw tuples from NIF
Route.centroid(route)            # {x, y}
Route.vehicle_type(route)
Route.start_depot(route)
Route.end_depot(route)
Route.num_trips(route)
Route.num_clients(route)         # uses local visits field, no NIF
```

## Stopping Criteria

```elixir
StoppingCriteria.max_iterations(10_000)
StoppingCriteria.max_runtime(60.0)           # seconds (float)
StoppingCriteria.no_improvement(500)
StoppingCriteria.first_feasible()
StoppingCriteria.multiple_criteria([...])    # OR logic (any triggers stop)
StoppingCriteria.any([...])                  # alias
StoppingCriteria.all([...])                  # AND logic (all must trigger)
StoppingCriteria.first_feasible_or(other)    # convenience combo
```

Stop functions are stateful (Agent-backed). `max_runtime` timer starts at `to_stop_fn/1` call, not at first ILS iteration.

## Penalty Manager

Targets 65% feasibility rate. Adjusts load/time-window/distance penalties every 500 solutions.

```elixir
pm = PenaltyManager.init_from(problem_data)           # auto-calibrate
pm = PenaltyManager.new(load_penalties, tw, dist)      # explicit
{:ok, cost_eval} = PenaltyManager.cost_evaluator(pm)   # current penalties
{:ok, max_eval} = PenaltyManager.max_cost_evaluator(pm) # max penalties
pm = PenaltyManager.register(pm, solution_ref)          # track + maybe adjust
```

Parameters: `solutions_between_updates: 500`, `penalty_increase: 1.25`, `penalty_decrease: 0.85`, `target_feasible: 0.65`, `min_penalty: 0.1`, `max_penalty: 100_000.0`.

For prize-collecting: `tw_penalty` is boosted so 1 minute of time warp costs as much as one prize, strongly discouraging violations.

## Fleet Minimisation

```elixir
{:ok, vehicle_type} = MinimiseFleet.minimise(model, stop, seed: 0)
```

Binary search: reduces `num_available` by 1, solves with `first_feasible_or(stop)`, continues until lower bound (capacity-based) is hit. Only works with single vehicle type and no optional clients.

## VRPLIB Reader

```elixir
model = ExVrp.Read.read("instance.vrp", round_func: :dimacs)
```

Round functions: `:none` (trunc), `:round`, `:trunc`, `:dimacs` (10x trunc), `:exact` (1000x round), or custom `fn`.

Supports: NODE_COORD, EDGE_WEIGHT, DEMAND, TIME_WINDOW, SERVICE_TIME, DEPOT, CAPACITY, BACKHAUL, LINEHAUL, PRIZE, RELEASE_TIME, MUTUALLY_EXCLUSIVE_GROUP, VEHICLES_DEPOT, VEHICLES_ALLOWED_CLIENTS, VEHICLES_RELOAD_DEPOT, VEHICLES_MAX_DURATION/DISTANCE, VEHICLES_FIXED_COST, VEHICLES_UNIT_DISTANCE_COST.

Handles: CVRP, VRPTW, VRPB (linehaul-before-backhaul), GTSP (required+mutually_exclusive groups), multi-depot, heterogeneous fleet, prize-collecting.

## NIF Layer

### C++ Resource Types

- **ProblemDataResource** — shared_ptr<ProblemData>
- **SolutionResource** — shared_ptr<Solution> + shared_ptr<ProblemData>
- **CostEvaluatorResource** — shared_ptr<CostEvaluator>
- **LocalSearchResource** — persistent across iterations, stores RNG state + computed neighbours
- **PerturbationManagerResource** — manages perturbation count
- **RandomNumberGeneratorResource** — RNG state

### Key NIF Functions

```
create_problem_data(model)             -> ProblemDataResource
create_solution_from_routes(pd, routes)-> SolutionResource
create_cost_evaluator(opts)            -> CostEvaluatorResource
create_local_search(pd, seed)          -> LocalSearchResource (computes neighbours once)
local_search_run(ls, sol, eval, timeout_ms)       -> {ok, SolutionResource}
local_search_search_run(ls, sol, eval, timeout_ms) -> {ok, SolutionResource}
solution_*                             -> various queries on SolutionResource
problem_data_*                         -> various queries on ProblemDataResource
```

### :infinity Handling

`:infinity` atoms in Elixir are converted to `INT64_MAX` (`9_223_372_036_854_775_807`) in the NIF layer. This applies to: `tw_late`, `shift_duration`, `max_distance`, `max_reloads`.

## Compilation

C++20 via elixir_make. Fine library for NIF ergonomics.

```
make_targets: ["all"]
make_env: %{"FINE_INCLUDE_DIR" => Fine.include_dir()}
```

Sources: `c_src/ex_vrp_nif.cpp` + `c_src/pyvrp/*.cpp` + `c_src/pyvrp/search/*.cpp`

Flags: `-std=c++20 -O3 -flto -DNDEBUG` (release), `-O1 -fsanitize=address,undefined` (with `SANITIZE=1`)

## Testing

### Test Files

| Test                                                         | Purpose                              |
| ------------------------------------------------------------ | ------------------------------------ |
| `model_test.exs`                                             | Model building + validation          |
| `solve_test.exs`                                             | End-to-end solve                     |
| `solution_test.exs`                                          | Solution queries                     |
| `route_test.exs`                                             | Route queries                        |
| `client_test.exs`, `depot_test.exs`, `vehicle_type_test.exs` | Struct construction                  |
| `client_group_test.exs`                                      | Group semantics                      |
| `same_vehicle_group_test.exs`                                | Same-vehicle constraints             |
| `stopping_criteria_test.exs`                                 | Stop conditions                      |
| `penalty_manager_test.exs`                                   | Penalty dynamics                     |
| `iterated_local_search_test.exs`                             | ILS behavior                         |
| `island_solver_test.exs`                                     | Parallel island ILS                  |
| `local_search_test.exs`                                      | NIF local search                     |
| `cost_evaluator_test.exs`                                    | Cost evaluation NIF                  |
| `problem_data_test.exs`                                      | ProblemData NIF                      |
| `neighbourhood_test.exs`                                     | Neighbourhood computation            |
| `perturbation_manager_test.exs`                              | Perturbation NIF                     |
| `pyvrp_api_test.exs`                                         | PyVRP API compatibility verification |
| `multi_trip_test.exs`                                        | Multi-trip / reload                  |
| `multi_dimensional_capacity_test.exs`                        | Multi-dim capacity                   |
| `minimise_fleet_test.exs`                                    | Fleet minimisation                   |
| `read_test.exs`                                              | VRPLIB parsing                       |
| `end_at_location_test.exs`                                   | Multi-depot end locations            |
| `vehicle_profile_test.exs`                                   | Multi-profile matrices               |
| `prize_collecting_edge_cases_test.exs`                       | Prize-collecting edge cases          |
| `reload_cost_test.exs`                                       | Reload costs                         |
| `timeout_test.exs`                                           | Runtime limits                       |
| `benchmark_test.exs`                                         | Benchmark suite                      |
| `statistics_test.exs`                                        | Stats collection                     |

### Running Tests

```bash
mix test                          # pure Elixir tests
mix test --include nif_required   # includes NIF-dependent tests
```

### Benchmarking

```bash
mix benchmark                     # all instances
mix benchmark --instances ok_small,rc208 --iterations 100
```

Benchmark data in `priv/benchmark_data/`. Compares against known best solutions.

## VRP Variant Support

| Variant              | How                                                                                         |
| -------------------- | ------------------------------------------------------------------------------------------- |
| Capacitated (CVRP)   | `capacity` on VehicleType, `delivery`/`pickup` on Client                                    |
| Time Windows (VRPTW) | `tw_early`/`tw_late` on Client + VehicleType                                                |
| Pickups & Deliveries | `pickup` + `delivery` on Client                                                             |
| Multi-depot          | Multiple `add_depot`, `start_depot`/`end_depot` on VehicleType                              |
| Heterogeneous fleet  | Multiple `add_vehicle_type` with different params                                           |
| Prize-collecting     | `prize > 0` + `required: false` on Client                                                   |
| Multi-trip           | `reload_depots` + `max_reloads` on VehicleType                                              |
| Mutually exclusive   | ClientGroup with `required: false` (or `required: true, mutually_exclusive: true` for GTSP) |
| Same-vehicle         | SameVehicleGroup                                                                            |
| Multi-profile        | `profile` on VehicleType + multiple matrices                                                |
| Fleet minimisation   | `MinimiseFleet.minimise/3`                                                                  |
| Shift/overtime       | `shift_duration`, `max_overtime`, `unit_overtime_cost` on VehicleType                       |

## Dependencies

- `fine ~> 0.1.4` — C++ NIF bindings
- `nx ~> 0.10` — neighbourhood computation (tensors)
- `elixir_make ~> 0.8` — NIF compilation
- `stream_data` — property-based testing (dev/test)
- `benchee` — benchmarking (dev/test)

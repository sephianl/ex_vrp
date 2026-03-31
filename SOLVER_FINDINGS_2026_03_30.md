# Solver Investigation Findings — 2026-03-30

## Trigger

Production benchmark test `oban-966289` failed twice in a row (107/108 clients planned). Investigation expanded into large production benchmark analysis.

## Benchmarks

### Small benchmarks (in test harness, base64-encoded)

| File        | Clients | Vehicles | SVGs | Dims | Status                           |
| ----------- | ------- | -------- | ---- | ---- | -------------------------------- |
| oban-966207 | 105     | 7        | 0    | 8    | PASS — consistent                |
| oban-966279 | 108     | 7        | 2    | 8    | PASS — consistent                |
| oban-966284 | 108     | 7        | 2    | 8    | PASS — consistent                |
| oban-966289 | 108     | 7        | 2    | 8    | PASS — was flaky, now consistent |

All clients have prize=150,000. No zone restrictions. No forbidden destinations. These benchmarks are small enough that the solver converges within 3-8 seconds, leaving 100+ seconds of margin for distance optimization.

### Large benchmarks (raw ETF, NOT in test harness)

| File                   | Clients | Vehicles | SVGs | Dims | Profiles | Status               |
| ---------------------- | ------- | -------- | ---- | ---- | -------- | -------------------- |
| captured_1774622392    | 764     | 53       | 6    | 8    | 8        | 2-3/6 seeds feasible |
| 2026-03-30_5d6a2c58... | 628     | 53       | 5    | 9    | 9        | Has P27 phantom dim  |

Both large benchmarks use raw ETF format with `%{model: model}` wrapper (not base64). They are NOT wired into the production benchmark test. Before adding them:

1. Extract the model from the wrapper: `data.model`
2. Prune unused capacity dimensions (dims where no client has demand — reduces solver overhead)
3. Zone penalties may change after Zelo fixes (P27 filter, SVG validation), so re-capture after those fixes
4. Base64-encode: `model |> :erlang.term_to_binary() |> Base.encode64()`
5. Rename to match `*_model.etf` pattern
6. The `2026-03-30` model needs P27 fixed in Zelo first (dim 7: all vehicles cap=0, 7 clients have demand)
7. The `captured` model should only be added once SVG feasibility is consistently solved (currently 2-3/6 seeds)

---

## Root Cause: Small Benchmark Flakiness

### Problem

`oban-966289` intermittently planned 107/108 clients. Some seeds found 108 in 3-8s, others never found it even with 172s.

### Root cause: tw_penalty initialization

The initial `tw_penalty` was `max_prize / 60.0 = 2500/s`. This created a knife-edge:

- 107-client feasible solution: penalisedCost = distance(85k) + durationCost + fixedCost + uncollectedPrizes(150k) ≈ 886k
- 108-client infeasible solution (with 60s time warp): penalisedCost = distance(90k) + durationCost + fixedCost + twPenalty×60 ≈ 891k

The 108-client solution was **barely worse** in penalisedCost. LAHC rejection was seed-dependent — some seeds happened to get a penalty decrease that crossed the threshold.

### Fix

Changed to `max_prize / 3600.0` (1 hour of time warp = 1 prize, matching the comment that always said 3600). This makes the infeasible 108-client solution clearly cheaper than the feasible 107-client one, so LAHC always accepts the transition.

### Secondary fix

`markMissingAsPromising` in LocalSearch.cpp: After perturbation, `unmarkAllPromising()` cleared all promising flags, and `markRequiredMissingAsPromising()` only re-marked required clients. Optional prize clients that weren't touched by perturbation were never evaluated for insertion. Renamed to `markMissingAsPromising` and added prize > 0 check.

---

## Root Cause: Large Benchmark Infeasibility

### Problem

The captured benchmark (764 clients, 53 vehicles) stays infeasible for the entire solve time (215s) on most seeds. When feasible, it drops 2 zone-restricted clients.

### Key finding: infeasibility = SVG violations, NOT route violations

After 10s of solving, ALL routes are individually feasible (0 time warp, 0 excess load, 0 excess distance). The solution is infeasible solely because **same-vehicle group members are on different routes**.

### Why SVG members get split

1. The initial solution construction (`search()`) inserts clients in random order
2. SVG members end up on different routes based on greedy insertion cost
3. `wouldViolateSameVehicle` prevents moving members AWAY from a partner's route, but it cannot bring separated members together
4. SVG partners are often NOT in each other's distance-based neighbourhood, so Exchange operators never try to swap them
5. Pre-pass `insertConstrainedFirst` places SVG members together, but the subsequent `search()` splits them (mechanism not fully understood — possibly via multi-step moves)

### Why the solver can't recover

1. The solver has **no gradient toward SVG feasibility** in route-level delta cost evaluation — Exchange operators can't "see" SVG violations
2. `penalisedCost` at the solution level includes a 500k SVG penalty (added in this session), but route-level delta costs used by move evaluation don't
3. `best_cost` stays at `:infinity` (all solutions are infeasible), so `iters_no_improvement` never resets without the infeasible tracking fix
4. With infeasible tracking, `iters_no_improvement` doesn't reset on infeasible improvements, allowing restarts to trigger

### Zone constraint analysis

**Profile distribution:**

- Profile 0: 45 vehicles (the "default" drivers)
- Profiles 1-7: 1-2 vehicles each (zone-familiar drivers)

**Zone-restricted clients:**

- 102 clients in 7 soft-constraint zones (3600s penalty for unfamiliar drivers)
- 25 hard-forbidden destinations (1 billion distance)
- Profile 5: 7 exclusive clients (only reachable from 1 vehicle)
- Profile 7: 5 exclusive clients (only reachable from 1 vehicle)

**Dropped clients (seed 999's feasible solution):**

- Client 303: prize=500k, tw=[21600..32400], reachable from profile 7 only
- Client 620: prize=500k, tw=[23400..39600], reachable from profile 7 only
- Both are profile-7-exclusive with 500k prize — the single profile-7 vehicle can't fit all 5 exclusive clients

### March 30th model additional issues

- **P27 phantom dimension (dim 7)**: 9 capacity dimensions but all 53 vehicles have cap=0 on dim 7, while 7 clients have demand. These clients can never be feasibly placed. Fix needed in Zelo's `collect_capacity_types`.
- **5 SVGs** (vs 6 in captured): 2 new SVGs compared to a working March 25 run. One has zero time-window overlap between members.

---

## All Code Changes (working tree, not committed)

### Critical fixes

| File                                 | Change                                          | Impact                                             |
| ------------------------------------ | ----------------------------------------------- | -------------------------------------------------- |
| `lib/ex_vrp/penalty_manager.ex`      | `/3600` tw_penalty init                         | Fixes small benchmark knife-edge                   |
| `c_src/pyvrp/search/LocalSearch.cpp` | `markMissingAsPromising`                        | Ensures prize clients evaluated after perturbation |
| `lib/ex_vrp/model.ex`                | Append instead of prepend, removed `finalize()` | Fixes group index bugs                             |

### Solver improvements

| File                                 | Change                           | Impact                                                                         |
| ------------------------------------ | -------------------------------- | ------------------------------------------------------------------------------ |
| `c_src/ex_vrp_nif.cpp`               | SwapStar commented out with TODO | Standard PyVRP operator, O(V²×N) — needs per-iteration timeout before enabling |
| `c_src/pyvrp/search/LocalSearch.cpp` | `wouldViolateForbidden`          | Prevents Exchange moves to zone-forbidden routes                               |
| `c_src/pyvrp/search/Solution.cpp`    | `isReachable` in insert          | Prevents inserting on zone-forbidden routes                                    |
| `c_src/pyvrp/search/LocalSearch.cpp` | `isHardToPlace`                  | Protects zone-restricted clients (≤2 profiles) from removal                    |
| `c_src/pyvrp/search/LocalSearch.cpp` | `insertConstrainedFirst`         | Pre-pass: SVG members together, then zone-restricted first                     |
| `c_src/pyvrp/search/LocalSearch.cpp` | `applySameVehicleRepair`         | Tries to unite split SVG members via exchange + 500k bonus                     |
| `c_src/pyvrp/CostEvaluator.h`        | SVG violation penalty            | 500k per violation in solution-level `penalisedCost`                           |
| `c_src/pyvrp/Solution.h/cpp`         | `numSameVehicleViolations_`      | Counts SVG violations for penalty                                              |

### ILS improvements

| File                                  | Change                              | Impact                                                                            |
| ------------------------------------- | ----------------------------------- | --------------------------------------------------------------------------------- |
| `lib/ex_vrp/iterated_local_search.ex` | `max_no_improvement: 5_000`         | Restarts trigger within solve time                                                |
| `lib/ex_vrp/iterated_local_search.ex` | Per-iteration timeout reverted to 0 | SwapStar disabled, timeout not needed — re-add when SwapStar is enabled           |
| `lib/ex_vrp/iterated_local_search.ex` | Infeasible tracking                 | Updates best with better infeasible solutions (without resetting restart counter) |
| `lib/ex_vrp/iterated_local_search.ex` | Fresh restart on infeasible         | Rebuilds initial solution with new seed on restart                                |
| `lib/ex_vrp/iterated_local_search.ex` | LAHC first-feasible acceptance      | Always accepts first feasible when best is infeasible                             |
| `lib/ex_vrp/solver.ex`                | Multi-start initial (best of 3)     | Reduces initial solution variance                                                 |

### Test/config changes

| File                                  | Change                             |
| ------------------------------------- | ---------------------------------- |
| `test/penalty_manager_test.exs`       | Updated assertion for `/3600`      |
| `test/iterated_local_search_test.exs` | Updated default assertion for 5000 |
| `test/model_test.exs`                 | Removed `Enum.reverse` workarounds |
| `test/read_test.exs`                  | Removed `Enum.reverse` workarounds |
| `test/same_vehicle_group_test.exs`    | Removed `Enum.reverse` workarounds |
| `.credo.exs`                          | Disabled AppendSingleItem check    |

---

## What was tested but didn't help

| Approach                                      | Result                           | Why                                                        |
| --------------------------------------------- | -------------------------------- | ---------------------------------------------------------- |
| `/600` tw_penalty (compromise)                | 0/4 feasible on large            | Penalty too high, solver can't accept infeasible solutions |
| `/60` tw_penalty on large benchmark           | 0/4 feasible, drops 8-13 clients | Too aggressive, forces client dropping                     |
| Equal 150k prizes (remove 500k premium)       | 2/4 different seeds              | Prize value isn't the main lever                           |
| `max_penalty: 1_000_000`                      | No improvement                   | Penalty ramp-up too slow to matter                         |
| Aggressive penalty escalation (squared at 0%) | 0/4, worse                       | Penalties too high, solver can't explore                   |
| Penalty boost for infeasible initial          | 0/4, worse                       | Starting penalties too high blocks LAHC                    |
| Scaled perturbation (25 → 38 for large)       | 0/4, worse                       | Too disruptive                                             |
| `max_no_improvement: 2_000`                   | 0/6, worse                       | Too many restarts, not enough search time                  |
| Forced SVG repair (ignore cost)               | Same 2/6                         | Search undoes the repair                                   |
| SVG bonus in delta cost (500k)                | Same 2/6                         | Only in solution-level cost, not route-level               |

---

## Next Steps (for next session)

### Priority 1: Understand SVG splitting in initial search

The `insertConstrainedFirst` pre-pass places SVG members together, but `search()` splits them. `wouldViolateSameVehicle` should prevent this. Need to trace exactly which move type splits them.

### Priority 2: SVG penalty in route-level delta costs

Exchange operators evaluate route-level delta costs which have no SVG component. Adding an SVG bonus when a move unites partners would give the search a gradient to follow.

### Priority 3: Add SVG members to neighbourhoods

Distance-based neighbourhoods miss SVG partners that are geographically far. Explicitly adding SVG members to each other's neighbourhoods would let Exchange operators try swapping them.

### Priority 4: Zelo fixes

- P27 phantom dimension: filter in `collect_capacity_types`
- Validate SVG time window overlap
- Consider zone-restricted prize value (500k may be counterproductive)

### Priority 5: Parallel multi-seed solving

Tested racing 8 seeds in parallel using `Task.async`. Results on captured benchmark (60s per seed, 120s total wall time):

```
2/8 feasible in 121s wall time
  Seed 999: 762/764 dist=581058 (dropped 2 zone-restricted clients)
  Seed 99999: 764/764 dist=663465 (all clients, fully feasible!)
```

The NIF runs on dirty schedulers so multiple solves run concurrently. CPU usage is high (8 cores) but wall time matches a single solve. This is a viable production strategy — run N seeds in parallel, take the first feasible result. Can be implemented in Zelo's planner without changing ExVrp.

**Key finding**: Seed 99999 found ALL 764 clients feasible — proving the problem IS solvable without dropping any clients. The solver just needs the right initial arrangement.

**Implementation sketch** (Zelo-side, not ExVrp):

```elixir
# In Zelo planner, wrap ExVrp.solve with multi-seed racing
tasks = for seed <- Enum.take_random(1..1_000_000, num_cores) do
  Task.async(fn -> ExVrp.solve(model, stop: stop, seed: seed) end)
end
# Take first feasible or best after timeout
results = Task.await_many(tasks, timeout_ms)
best = results
|> Enum.filter(fn {:ok, r} -> r.best.is_feasible end)
|> Enum.min_by(fn {:ok, r} -> r.best.distance end, fn -> hd(results) end)
```

### Priority 6: Upstream branch performance investigation

The `update-to-upstream` branch has a significant performance regression:

- Halved iteration throughput (~61 iter/s vs ~123 iter/s on main)
- Removed the `search()` → `intensify()` loop (only calls `search()` once per iteration)
- 0/5 seeds found all clients on the small benchmark (vs 2/5 on main without fixes)
- The upstream changes are architecturally good (unified operator system) but need performance tuning before adoption

---

## Performance Reference

### Small benchmarks (108 clients, 7 vehicles)

- Time to all clients planned: 3-8 seconds
- Time to distance-optimized: ~114 seconds
- Iterations: ~14,000 in 114s (~123 iter/s)
- Distance improvement after feasibility: ~3-4% (88k → 86k)

### Large benchmark (764 clients, 53 vehicles)

- Initial solution construction: ~2s per solution (best of 3 = ~5s)
- ILS iterations: ~100 iter/s
- Time to feasibility (when found): 25-40 seconds
- Restart triggers at ~5000 iterations (~50s)
- SwapStar per-iteration timeout: 30s (prevents hanging)
- Parallel 8-seed race: ~120s wall time, 2/8 feasible
- The 2 dropped clients (when solution is 762/764): always clients 303 and 620 — profile-7-exclusive with 500k prize

### Zone constraint details (captured benchmark)

- 7 soft-constraint zones with 1 preferred driver each
- 102 total zone-penalized client destinations (13% of all clients)
- 3600s penalty per unfamiliar visit (added to distance matrix only, not duration)
- 25 hard-forbidden destinations (1 billion distance)
- Profile 0 (45 vehicles): penalized for all 102 zone clients
- Profile 5 (1 vehicle): 7 exclusive clients
- Profile 7 (1 vehicle): 5 exclusive clients (clients 303, 620 are in this set)

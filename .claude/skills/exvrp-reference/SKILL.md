---
name: exvrp-reference
description: ExVRP internals the code docs don't carry — solve pipeline, ILS loop, how each constraint is enforced in the C++ search (penalties, forbidden locations, vehicle locks), warm starts, fork history vs PyVRP, and test/benchmark map. Use before changing the solver, adding a constraint or move operator, or debugging solution quality.
---

# ExVRP Reference

**API surface lives in the code, not here.** Read the `@moduledoc`/`@doc`/`@type` in
`lib/ex_vrp/*.ex` for options, fields and defaults (`vehicle_type.ex`, `client.ex`, `model.ex`,
`solution.ex`, `route.ex`, `solver.ex`). Build/test commands and the force-build gotcha are in
CLAUDE.md; release history in CHANGELOG.md. This file holds what those don't: how things work
inside, why they are the way they are, and what breaks if you forget.

## Layers

```
ExVrp.solve/2 → Solver (multi-start, warm start) → IteratedLocalSearch (Elixir driver, LAHC)
  → ExVrp.Native (Fine NIFs, c_src/ex_vrp_nif.cpp)
  → c_src/ex_vrp/ (vendored PyVRP core) + c_src/ex_vrp/search/ (LocalSearch, operators)
Model → Model.validate/1 → to_problem_data → C++ ProblemData (immutable, shared_ptr resource)
```

## Solve Pipeline (`Solver.solve/2`)

1. Options merged; `stop_fn` built early — `max_runtime`'s clock starts at `to_stop_fn/1`, not at
   the first iteration. Stop functions are stateful (Agent-backed).
2. `Model.to_problem_data` → `create_problem_data`.
3. `PenaltyManager.init_from(problem_data)` calibrates initial penalties. Prize-collecting boosts
   `tw_penalty` so one minute of time warp costs about one prize.
4. `create_local_search(pd, seed)` — persistent resource; neighbours computed once.
5. Initial solution: empty solution + `local_search_search_run` (search only, no perturbation) —
   or a warm start from `:initial_routes` (per vehicle type: flat client list, or
   `{:trips, [...]}` for multi-trip; see the option's `@doc`). Structurally invalid seeds warn and
   fall back to cold. An infeasible seed is **trimmed** by dropping the least-violating visits
   (`Solver` trim, 0.12.1): each candidate is rebuilt from `Native.solution_trips/1` as a
   `{:trips, ...}` start, so multi-trip routes keep their reloads. The trim ranks by
   `violation_score/1` — completeness and group feasibility first, because dropping only worsens
   those.
6. `num_starts` ILS chains in parallel (`:auto` = `div(schedulers_online, 2)`), best kept. Ours,
   not upstream (single trajectory).

### ILS loop (`iterated_local_search.ex`)

Per iteration: maybe_restart → `local_search_run` (perturb + search) → LAHC accept → register
with PenaltyManager (adjusts every 500 solutions toward 65% feasible) → progress callback (~1s).

- **Best** compares `cost()` (`:infinity` if infeasible). **Acceptance** compares
  `penalised_cost()` against both the late (history) and current cost.
- **exhaustive_on_best** (default true, PyVRP #988): each new best gets a non-perturbing polish.
- **Restart** at `Params.max_no_improvement` = **800** (upstream 150_000; rationale at
  `iterated_local_search.ex` `Params`): reset current to best (fresh solution if best is
  infeasible), clear LAHC history, keep iterating. A restart is not a stop.

Two limiters, easy to confuse: the restart counter resets on new best **and** on restart;
`StoppingCriteria.no_improvement(N)` cancels the whole solve and resets **only** on new best.
Zelo sets `N = max(2000, n*50)` alongside `max_runtime`, so a stalled chain gets roughly
`N / 800` restarts before Zelo cancels it. ex_vrp's benchmarks use `max_runtime` only and do not
reproduce that cancel.

## Constraint Mechanisms

| Need                         | Mechanism                                                             | Enforced as                     |
| ---------------------------- | --------------------------------------------------------------------- | ------------------------------- |
| Capacity, multi-dim          | `capacity`, `delivery`/`pickup`                                       | penalty (load)                  |
| Time windows, shifts         | client/vehicle `tw_*`, `shift_duration`, overtime fields              | penalty (time warp)             |
| Time worked cap              | `max_working_duration` — travel + service, not waiting                | penalty                         |
| Distance caps                | `max_distance`, `max_distance_per_trip` (resets at each reload)       | penalty                         |
| Driver breaks                | `forbidden_windows` on VehicleType (vehicle idle in window)           | local patch, see its tests      |
| Multi-trip                   | `reload_depots`, `max_reloads`, depot `reload_cost`                   | structure + cost                |
| Optional clients             | `prize > 0`, `required: false`                                        | objective                       |
| At most / exactly one of     | ClientGroup (`required`, `mutually_exclusive`)                        | structure                       |
| Same vehicle                 | SameVehicleGroup                                                      | feasibility (`isGroupFeas_`)    |
| Soft zone cost               | `Model.set_penalties/2` per (profile, location)                       | objective (penalty channel)     |
| Hard zone ban                | `Model.set_forbidden/2` per profile                                   | pruned in search                |
| Keep client on its vehicle   | `Model.set_vehicle_locks/2` per location → vehicle type               | objective (penalty channel)     |
| Fewer vehicles               | `MinimiseFleet.minimise/3` — single vehicle type, no optional clients | outer binary search             |

Locations carry **no coordinates**: distance matrices (one per profile) are mandatory;
`Model.set_euclidean_matrices/2` derives them explicitly in location order (depots first).
Never encode unreachability as a huge distance — the `1_000_000_000` sentinel is not a contract;
use `set_forbidden/2`.

### Penalty channel (`set_penalties/2`, vehicle locks)

A **real objective term**, not an infeasibility penalty: it survives on feasible solutions and a
big enough prize outbids it. Node-additive, so every move prices it through the same path:
`ProblemData::penalty(profile, loc) + lockPenalty(vehicleType, loc)` feeds search-route
`cumPenalty`, `ClientSegment`, `SegmentBetween`, and the solution-side `Route` constructor.
`Solution.penalty_cost/1` is the channel total; `lock_cost/1` its lock share.

- **Adding a term to the channel:** every one of those four sites must see it, or move deltas
  diverge from solution cost (`SANITIZE=1` asserts `costAfter == costBefore + deltaCost`).
- **`SegmentBetween` recompute:** crossing routes must re-price when the **vehicle type** differs,
  even with equal profiles — locks key on vehicle type (one Zelo vehicle = one vehicle type,
  `num_available: 1`). `SegmentAfter`/`SegmentBefore` stay within their own route.
- Vehicle locks replaced the 0.12.2 trick of holding a dock with a whole-route same-vehicle group
  (and its perturbation guard, removed in 0.13.0).

### Forbidden locations (`set_forbidden/2`)

Hard: pruned, never priced, so no prize reaches it. Enforced only in the search layer, so every
path that places a client checks `ProblemData::isAllowed` itself: `Solution::insert`, in-place
swaps, `improveWithMultiTrip`, `insertConstrainedFirst`, route operators (`mayExchangeClients`),
and node operators — subtly, `Exchange<2,*>` carries `n(U)` and `SwapTails` whole tails, so the
gate reads `spanU()`/`spanV()`/`affectsEntireTail()`. **Any new move operator must be gated.**
`Solution.num_forbidden_visits/1` is the backstop; it is deliberately not part of `feasible?/1`
(no penalty gradient, so the search could not repair it).

### Validation

`Model.validate/1` must return `{:error, messages}` for any malformed input — never raise, never
reach the NIF with something it would crash on. Out-of-range indices are errors at both layers,
never silent drops. Messages that interpolate user input use `inspect/1`.

## Fork Point & Upstream Divergence

### Why there is no genetic algorithm (settled — stop re-deriving this)

**PyVRP dropped it, not us.** v0.13.0 replaced hybrid genetic search with ILS + late-acceptance
hill-climbing and deleted `SubPopulation`, SREX crossover, broken-pairs-distance diversity, the
`repair` module (#970) and its infeasible-solution booster. Timeline: PR #778 "Iterated local
search" merged 2025-12-22 (closing #533) → **ExVRP's first commit `d97ad57`, already ILS, already
no `crossover/`** → v0.13.0 tagged 2026-01-15. Verified against the v0.14.0 tree:
`IteratedLocalSearch.py` present; no `GeneticAlgorithm.py`, `Population.py`, `crossover/`,
`diversity/`.

Upstream's reasons: ILS is "conceptually much simpler" (#533), and it wins where users operate —
v0.13.0 notes claim _"better solution quality when solving with limited runtimes (up to a few
minutes) and/or large instances (already from 500 clients)"_; #778 reports MDVRPTW 10-min gap
1.72% → 0.90%. Population diversity compounds over millions of iterations; a 60-second solve runs
~10k. That short-budget regime is Zelo's.

Two traps:

1. **The paper contradicts the code.** PyVRP's citation — Wouda, Lan & Kool (2024), _INFORMS J.
   Computing_ 36(4):943-955, doi:10.1287/ijoc.2023.0055 — says it "implements hybrid genetic
   search." It predates v0.13.0; anything citing PyVRP ≥ 0.13 misdescribes what it ran.
   `introduction_to_hgs.html` now 404s.
2. **"Not genetic" understates the inheritance.** Only the population layer died. The _hybrid_
   half of HGS is intact here: Exchange/2-opt/relocate with concatenation-based delta evaluation,
   the Toth-Vigo granular neighbourhood, and the dynamic penalty scheme targeting ~65% feasible.
   We still run Vidal's algorithm, driven by restart + LAHC instead of a gene pool.

### What we changed vs inherited

| Thing                        | ex_vrp          | PyVRP @ fork   | PyVRP today      | Notes                                                                                                                         |
| ---------------------------- | --------------- | -------------- | ---------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Driver                       | Elixir          | Python         | Python           | Faithful; upstream's `cpp/` never had an ILS driver either                                                                    |
| `num_neighbours`             | **60**          | 50             | 50               | Our bump (`neighbourhood_params.ex`)                                                                                          |
| `weight_time_warp`           | 1.0             | 1.0            | removed          | Inherited                                                                                                                     |
| `weight_wait_time`           | 0.2             | 0.2            | 0.2              | Faithful                                                                                                                      |
| SwapStar                     | **removed**     | off by default | operator removed | Ours: 21 instances × 4 seeds, no gain beyond noise, throughput −13% (−33–90% on large)                                        |
| Restart `max_no_improvement` | **800**         | 150_000        | 150_000          | Ours (`c169cd0`): upstream's assumes millions of iterations; 153-order instance: 3–6 restarts/start, +29% iterations          |
| `exhaustive_on_best`         | on              | post-fork #988 | present          | Ported; short-budget A/B slightly negative — validate at prod budgets                                                         |
| LAHC history                 | 500             | 300            | 300              | Minor                                                                                                                         |

Local feature patches in the vendored core (not upstream lag): same-vehicle groups, forbidden
windows, reload/multi-trip pricing, depot-service removal, penalty channel, forbidden locations,
vehicle locks.

## NIF Layer

Resources are reference-counted `shared_ptr`s: `ProblemData`, `Solution` (holds its
`ProblemData`), `CostEvaluator`, `LocalSearch` (persistent: RNG state + neighbours),
`PerturbationManager`, `RandomNumberGenerator`. `:infinity` → `INT64_MAX` at the NIF boundary.
`local_search_run(..., exhaustive: true)` skips perturbation; `local_search_search_run` is
search-only (initial solution).

## Tests & Benchmarks

Most test files are named for what they cover. The non-obvious ones:

| File                                                           | Covers                                                        |
| -------------------------------------------------------------- | ------------------------------------------------------------- |
| `warm_start_repair_test.exs`                                   | Infeasible warm-start trim                                    |
| `multi_trip_test.exs`                                          | Reloads, plus `{:trips, ...}` warm starts                     |
| `multi_trip_pricing_test.exs`                                  | New-trip pricing in `improveWithMultiTrip`                    |
| `same_vehicle_group_pricing_test.exs`                          | What a split group costs the search                           |
| `penalty_channel_test.exs`, `vehicle_lock_test.exs`            | Channel terms: validation, solution cost, move deltas         |
| `is_allowed_test.exs`                                          | Forbidden-location pruning and operator gating                |
| `oscillation_prevention_test.exs`                              | Prize-collecting insert/remove oscillation                    |
| `primitives_test.exs`, `pyvrp_api_test.exs`                    | Exact parity with PyVRP's own tests/API                       |
| `production_benchmark_test.exs`                                | Real-planning corpus (tagged; excluded by default)            |

Benchmark caveats:

- The production corpus (`priv/benchmark_data/production/`, anonymized Model ETF snapshots)
  asserts feasibility + `>= min(400, plannable)` clients under `max_runtime` only — not Zelo's
  stopping regime.
- `dev/ab_benchmark/` `Runner` + `Comparator.compare/2` (0.5% aggregate-objective threshold) back
  `mix bench.run`/`bench.compare`/`bench.smoke`. `Runner` does not vary `ils_params`; to A/B an ILS
  param, write a directed script passing `ils_params:` per variant at equal budget and seed.

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
   (`Solver` trim, 0.12.1): each candidate is rebuilt through `WarmStart.from_trips/1`, the same
   conversion `Solution.warm_start/1` exposes, so multi-trip routes keep their reloads. The trim ranks by
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

| Need                       | Mechanism                                                                | Enforced as                                            |
| -------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------ |
| Capacity, multi-dim        | `capacity`, `delivery`/`pickup`                                          | penalty (load)                                         |
| Time windows, shifts       | client/vehicle `tw_*`, `shift_duration`, overtime fields                 | penalty (time warp)                                    |
| Time worked cap            | `max_working_duration` — travel + service, not waiting                   | penalty                                                |
| Distance caps              | `max_distance`, `max_distance_per_trip` (resets at each reload)          | penalty                                                |
| Driver breaks              | `forbidden_windows` on VehicleType (vehicle idle in window)              | local patch, see its tests                             |
| Breaks between limits      | `max_drive/work_between_breaks` + `break_duration`, pooled break clients | search: virtual breaks; `BreakRepair` places real ones |
| Multi-trip                 | `reload_depots`, `max_reloads`, depot `reload_cost`                      | structure + cost                                       |
| Optional clients           | `prize > 0`, `required: false`                                           | objective                                              |
| At most / exactly one of   | ClientGroup (`required`, `mutually_exclusive`)                           | structure                                              |
| Same vehicle               | SameVehicleGroup                                                         | feasibility (`isGroupFeas_`)                           |
| Soft zone cost             | `Model.set_penalties/2` per (profile, location)                          | objective (penalty channel)                            |
| Hard zone ban              | `Model.set_forbidden/2` per profile                                      | pruned in search                                       |
| Keep client on its vehicle | `Model.set_vehicle_locks/2` per location → vehicle type                  | objective (penalty channel)                            |
| Fewer vehicles             | `MinimiseFleet.minimise/3` — single vehicle type, no optional clients    | outer binary search                                    |
| Pickup then delivery       | `Model.add_shipment/4` ties two clients                                  | structure (moves that break it are never made)         |

Locations carry **no coordinates**: distance matrices (one per profile) are mandatory;
`Model.set_euclidean_matrices/2` derives them explicitly in location order (depots first).
`Model.set_profiles/2` lets profiles share a matrix pair and replace one row each (Zelo's depot
row dated per departure hour): `ProblemData::distanceMatrix(profile)` is then a `MatrixView`
over the shared `Matrix`, and a matrix may be a binary of little-endian int64s (`ExVrp.Matrix`),
which the NIF copies rather than walks.
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

### Breaks between limits

`ExVrp.Breaks` appends a shared pool of break clients (no location, zero matrix rows) after the
user's clients. Breaks are route nodes but never neighbours, so no operator places one. Two prices
of the same route coexist, and mixing them up is the trap:

- **Search price** (`search::Route`, `Proposal::duration()`): a stretch no break covers is charged
  as the breaks it lacks (`DriveClock::missing`, max over both clocks) appended before the end
  depot, through the shared `Route::summarise()`. Clock overrun is **not** time warp here. `k`
  depends on the proposal, so it is never cached in `durAt/durBefore/durAfter`.
- **True price** (`ex_vrp::Route`, what the ILS sees): overrun is time warp. `BreakRepair`
  materialises virtual breaks whenever that lowers true overrun, _whatever the delta_, and
  releases a break only if true overrun does not grow — change either rule and it oscillates or
  strips needed breaks. `LocalSearch` repairs breaks after every round and before every `unload()`.
  The in-loop repair pays for itself (moving it after the loop lost 0.6–4% at equal time: the
  search needs real breaks in place to see where a break costs nothing), but search and repair can
  return each other to the same solution, so a round that moved breaks only earns another round
  if it lowered `LocalSearch::penalisedCost()`.
- Their zero matrix rows make a break every client's "nearest" location, so anything that ranks
  locations must skip them: the C++ `build_neighbours`, `ExVrp.Neighbourhood`, and
  `SearchSpace::setNeighbours`, which rejects a neighbourhood that lists one.
- Breaks are not clients: `numClients()`/`empty()` and `Proposal::empty()` skip them, so operator
  fixed-cost terms must count clients, not ask whether the next node is a depot (SwapTails,
  Exchange). Delta exactness is covered by `break_nodes_test.exs` and SANITIZE's
  `costAfter == costBefore + deltaCost`.
- **Rests** (0.16.0, groundwork for daily rests) are break clients flagged `isRest` that last
  `VehicleType::restDuration` instead of `breakDuration`, through `ProblemData::pauseDuration`,
  which reads the packed `isRest_` rather than the wide `Client`. Every path that prices a break
  node must go through it, and `SegmentBetween::durationWithBreaks`
  swaps both durations when evaluating for another vehicle type. A rest closes both clocks like a
  break, but `BreakRepair` neither places one (not in `breaks_`, and `BreakSegment` asserts it)
  nor releases one from a route with clients; only `stripBreaks` drops it, with every break on a
  route without clients or a break rule. Nothing places a rest yet, so the only way in is
  `:initial_routes`, where `Solution.warm_start/1` keeps it as its index rather than a `:break`
  marker. The search can still shed one by moving every client off its route. Covered by
  `rest_nodes_test.exs`.

### Forbidden locations (`set_forbidden/2`)

Hard: pruned, never priced, so no prize reaches it. Enforced only in the search layer, so every
path that places a client checks `ProblemData::isAllowed` itself: `Solution::insert`, in-place
swaps, `improveWithMultiTrip`, `insertConstrainedFirst`, route operators (`mayExchangeClients`),
and node operators — subtly, `Exchange<2,*>` carries `n(U)` and `SwapTails` whole tails, so the
gate reads `spanU()`/`spanV()`/`affectsEntireTail()`. **Any new move operator must be gated.**
`Solution.num_forbidden_visits/1` is the backstop; it is deliberately not part of `feasible?/1`
(no penalty gradient, so the search could not repair it).

### Shipments (`add_shipment/4`)

Two ordinary clients plus a pairing (`ProblemData::Shipment`), not upstream's separate index
space: every client-keyed feature (penalties, locks, forbidden, same-vehicle groups, neighbours)
applies to each half unchanged. The invariant: **a routed delivery has its pickup earlier on the
same route and trip**. A pickup alone is valid; its goods ride back to the depot.

- **Load needs no new segment type.** `ProblemData::shipmentLoad` is +amount at the pickup and
  −amount at the delivery, added to the client's pickup by the `LoadSegment(data, client, dim)`
  constructor, which every client segment goes through. Vidal's merge is exact for a negative
  pickup. It is why a shipment cannot cross a reload: `finalise` drops the amount on board.
- **Search side.** Each `Route::Node` of a half knows its `partner()` (set by `search::Solution`).
  `Route::isShipmentClosed` (a moved segment takes both halves or neither),
  `Route::keepsShipmentOrder` (a same-route relocate keeps the pickup first: that is how a half
  moves alone) and `Route::carriesShipmentAfter` (no tail swap or reload depot cuts a pair) gate
  `Exchange`, `SwapTails`, `RelocateWithDepot` and the multi-trip passes. Removal goes through
  `Route::removeWithDependents`, and `removeCost` prices a pickup with its delivery.
  `search::Solution::insert` inserts a delivery after its pickup, or the pair together; an
  unrouted pickup whose delivery is unrouted too tries the pair first (`insertShipment`) and goes
  alone only if that does not improve. `RelocateShipment` moves a pair across routes. Both try the
  delivery directly after the pickup or after one of the delivery's own granular neighbours, not
  at every later position: the full scan cost ~30% of a production iteration.
- **Full days.** On an oversubscribed prize-collecting day nothing inserts profitably at a local
  optimum, and a delivery can only go after its pickup on that pickup's route, so it loses to
  clients that fit anywhere. `LocalSearch::insertAfterPickupEjecting` lets an unrouted delivery in
  at its cheapest place after its pickup by ejecting the optional client on that route whose
  removal makes room best (`insertEjectingCost`). `inplaceCost` prices a shipment half like any
  client, except a delivery away from its pickup's trip or a pickup with its delivery on board.
  `prodship_seed_410081_hang` is the instance that shows it (8 → 10–13 of 57 deliveries).
- **Any new move operator must keep pairs together**, like the forbidden-location gate above.
  Debug builds assert `LocalSearch::shipmentsIntact` after every applied move.
- **Crossing a reload is the follow-up** (ZELO-4290): drop-and-reload at a depot, priced as a
  depot delivery on the delivery's trip.

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

| Thing                        | ex_vrp      | PyVRP @ fork   | PyVRP today      | Notes                                                                                                                |
| ---------------------------- | ----------- | -------------- | ---------------- | -------------------------------------------------------------------------------------------------------------------- |
| Driver                       | Elixir      | Python         | Python           | Faithful; upstream's `cpp/` never had an ILS driver either                                                           |
| `num_neighbours`             | **60**      | 50             | 50               | Our bump (`neighbourhood_params.ex`)                                                                                 |
| `weight_time_warp`           | 1.0         | 1.0            | removed          | Inherited                                                                                                            |
| `weight_wait_time`           | 0.2         | 0.2            | 0.2              | Faithful                                                                                                             |
| SwapStar                     | **removed** | off by default | operator removed | Ours: 21 instances × 4 seeds, no gain beyond noise, throughput −13% (−33–90% on large)                               |
| Restart `max_no_improvement` | **800**     | 150_000        | 150_000          | Ours (`c169cd0`): upstream's assumes millions of iterations; 153-order instance: 3–6 restarts/start, +29% iterations |
| `exhaustive_on_best`         | on          | post-fork #988 | present          | Ported; short-budget A/B slightly negative — validate at prod budgets                                                |
| LAHC history                 | 500         | 300            | 300              | Minor                                                                                                                |

Local feature patches in the vendored core (not upstream lag): same-vehicle groups, forbidden
windows, reload/multi-trip pricing, depot-service removal, penalty channel, forbidden locations,
vehicle locks.

Local speed patch: `CostEvaluator::deltaCost` prices only `ProblemData::loadedDimensions()` (a
copy lives on each `search::Route`, next to its load data), not every load dimension. Exact:
nothing can exceed capacity in a dimension no client or vehicle type loads. Zelo models declare
every capacity type its vehicles carry but the production plannings use one, so 5 of 8 dimensions are
unused: −23–34% instructions per iteration on the production corpus. Tried and dropped: a
delivery prefix sum for `SegmentBetween::load()` on pickup-free dimensions — exact, but no
measurable gain, as long between-segments are rare.

## NIF Layer

Resources are reference-counted `shared_ptr`s: `ProblemData`, `Solution` (holds its
`ProblemData`), `CostEvaluator`, `LocalSearch` (persistent: RNG state + neighbours),
`PerturbationManager`, `RandomNumberGenerator`. `:infinity` → `INT64_MAX` at the NIF boundary.
`local_search_run(..., exhaustive: true)` skips perturbation; `local_search_search_run` is
search-only (initial solution).

## Tests & Benchmarks

Most test files are named for what they cover. The non-obvious ones:

| File                                                | Covers                                                |
| --------------------------------------------------- | ----------------------------------------------------- |
| `warm_start_repair_test.exs`                        | Infeasible warm-start trim                            |
| `multi_trip_test.exs`                               | Reloads, plus `{:trips, ...}` warm starts             |
| `multi_trip_pricing_test.exs`                       | New-trip pricing in `improveWithMultiTrip`            |
| `same_vehicle_group_pricing_test.exs`               | What a split group costs the search                   |
| `penalty_channel_test.exs`, `vehicle_lock_test.exs` | Channel terms: validation, solution cost, move deltas |
| `is_allowed_test.exs`                               | Forbidden-location pruning and operator gating        |
| `shipment_property_test.exs`                        | Shipment precedence and load, from first principles   |
| `oscillation_prevention_test.exs`                   | Prize-collecting insert/remove oscillation            |
| `primitives_test.exs`, `pyvrp_api_test.exs`         | Exact parity with PyVRP's own tests/API               |
| `production_benchmark_test.exs`                     | Real-planning corpus (tagged; excluded by default)    |

Benchmark caveats:

- The production corpus (`priv/benchmark_data/production/`, anonymized Model ETF snapshots)
  asserts feasibility + `>= min(400, plannable)` clients under `max_runtime` only — not Zelo's
  stopping regime.
- `dev/ab_benchmark/` `Runner` + `Comparator.compare/4` (0.5% aggregate-objective threshold) back
  `mix bench.run`/`bench.compare`/`bench.smoke`. `Runner` does not vary `ils_params`; to A/B an ILS
  param, write a directed script passing `ils_params:` per variant at equal budget and seed.
- Speed is `Speed` + `SpeedComparison` behind `mix bench.speed`: instructions per iteration at a
  fixed iteration count, counted by Callgrind inside NIF calls only, so exactly repeatable and free
  of the BEAM. The CI A/B counts on GitHub-hosted runners (no PMU there, hence Valgrind rather than
  `perf`; the self-hosted fleet serves only private repos) and fails when the median instance runs
  more than 1% more. Valgrind cannot run the BEAM JIT, so solves run on the interpreter-only Erlang
  of `dev/ab_benchmark/interpreter_erlang.nix`. Iterations within a wall-clock budget are not a
  speed measure: unchanged code swung −8%…+22% per instance on hosted runners.

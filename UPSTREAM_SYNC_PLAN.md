# ExVRP Upstream Sync Plan

## Context

Ex_vrp (v0.2.2) is an Elixir NIF wrapper around PyVRP's C++ core, forked at ~v0.13.0. Upstream PyVRP has continued evolving through v0.13.3 and beyond on `main`, with significant C++ architecture changes, new operators, bug fixes, and removed components. The sephianl/PyVRP fork is also behind upstream.

This plan syncs ex_vrp's C++ core with upstream and adds EPyVRP-inspired algorithmic improvements. Each phase is independently deployable and backward-compatible with Zelo's usage.

**Consumer context**: Zelo uses prize-collecting (`required: false`, `prize: 100_000`), ClientGroups (disjunctive time windows), SameVehicleGroups (equipment), multi-depot, multi-profile matrices, and custom OSRM matrices.

## Dependency Graph

```
Phase 1 (Operator Interface)
    │
    v
Phase 2 (New Operators + Remove Primitives)
    │
    v
Phase 3 (Remove SwapRoutes/SwapStar + Bug Fixes)
    │
    ├──────────────────┐
    v                  v
Phase 4              Phase 5
(Neighbourhood→C++)  (Data Model)
    │                  │
    └────────┬─────────┘
             v
Phase 6 (Island ILS — pure Elixir)
```

---

## Phase 1: Operator Interface Modernization — Size: L ✅ DONE

**Goal**: Align operator base classes and evaluate() return type with upstream. This unblocks all subsequent phases.

**What changed**:

- `NodeOperator`/`RouteOperator` → `UnaryOperator`/`BinaryOperator` (variadic template on `Route::Node *`)
- `evaluate()` returns `std::pair<Cost, bool>` internally; NIFs extract `.first` and keep returning `int64_t`
- `init()` takes `Solution &` (non-const search::Solution) instead of `pyvrp::Solution const &`
- `addNodeOperator()` → `addOperator()`, kept `addRouteOperator()` for SwapRoutes/SwapStar
- `NodeOperator` kept as backward-compat alias for `BinaryOperator`
- `routeOps` kept as separate `vector<BinaryOperator *>` — merging into `binaryOps` would break RelocateWithDepot's `assert(!U->isDepot())`

**Files modified**:
| File | Change |
|------|--------|
| `c_src/pyvrp/search/LocalSearchOperator.h` | Variadic template, `UnaryOperator`/`BinaryOperator` aliases, `NodeOperator` compat alias, removed `RouteOperator` |
| `c_src/pyvrp/search/Exchange.h` | Base → `BinaryOperator`, evaluate returns `pair<Cost, bool>` |
| `c_src/pyvrp/search/SwapTails.{h,cpp}` | Base → `BinaryOperator`, evaluate returns pair |
| `c_src/pyvrp/search/RelocateWithDepot.{h,cpp}` | Base → `BinaryOperator`, evaluate returns pair |
| `c_src/pyvrp/search/SwapRoutes.{h,cpp}` | Base → `BinaryOperator`, takes `Route::Node *` args, extracts routes via `->route()` |
| `c_src/pyvrp/search/SwapStar.{h,cpp}` | Base → `BinaryOperator`, takes `Route::Node *` args, renamed loop vars to avoid shadowing |
| `c_src/pyvrp/search/LocalSearch.{h,cpp}` | `nodeOps` → `binaryOps`, added `unaryOps`, `applyNodeOps` → `applyBinaryOps`, destructures `auto [deltaCost, applied]` |
| `c_src/ex_vrp_nif.cpp` | Updated operator types, `addNodeOperator` → `addOperator`, evaluate NIFs extract `.first` from pair |

**Elixir changes**: None needed.

**Verified**: 960/960 tests pass, benchmarks show no quality regression.

---

## Phase 2: New Operators + Remove Primitives — Size: L ✅ DONE

**Goal**: Add new operators that replace the inline custom logic in LocalSearch.cpp. Remove primitives.h/cpp.

**What changed**:

- Evaluate return semantics shifted: `{cost, false}` → `{cost, cost < 0}` (operator decides via bool, not caller via `deltaCost < 0`). All existing operators (Exchange, SwapTails, RelocateWithDepot, SwapStar) updated. `applyBinaryOps`/`applyRouteOps` now check `shouldApply` instead of `deltaCost < 0`.
- Exchange.h: added `!U->route()` guard since search loop now iterates unrouted clients
- `markRequiredMissingAsPromising()` replaced by `ensureStructuralFeasibility()` (pulled forward from Phase 3 plan — needed because inline insertion logic was removed)
- `applyUnaryOps()` added — iterates unary operators, handles unrouted→routed transition
- Fallback optional client insertion via `Solution::insert()` in `applyUnaryOps` (replaces upstream's InsertOptional BinaryOperator — simpler, greedy best-position approach)
- `update(Route *U, Route *V)` now handles null U (needed for unrouted→routed transitions)
- `insertCost()` moved from primitives to file-scope function in `Solution.cpp` (still used by `Solution::insert`)

**New files created**:
| File | Type | Replaces |
|------|------|----------|
| `RemoveOptional.{h,cpp}` | UnaryOperator | inline `applyOptionalClientMoves` (remove) |
| `ReplaceOptional.{h,cpp}` | UnaryOperator | inline optional swap logic (searches neighbours for best swap) |
| `ReplaceGroup.{h,cpp}` | UnaryOperator | inline `applyGroupMoves` |
| `RemoveAdjacentDepot.{h,cpp}` | UnaryOperator | inline `applyDepotRemovalMove` |
| `ClientSegment.h` | Segment type | anonymous class in primitives.cpp |

**Divergences from upstream**:

- No `InsertOptional` BinaryOperator — replaced by `Solution::insert()` fallback in `applyUnaryOps`
- `ReplaceOptional` is a UnaryOperator (not BinaryOperator) — searches neighbours internally for best swap target
- No `DepotSegment.h` — not needed by any current operator
- `RemoveOptional` has SameVehicleGroup awareness (won't remove a client if it has a same-vehicle group member on the route)
- `ReplaceOptional` has SameVehicleGroup awareness (won't swap if target has a same-vehicle group member)
- All operators use `data.location()` (our API) not `data.client()` (upstream API)
- New operators use `deltaCost<true>` (exact evaluation) not the default non-exact

**Files modified**:
| File | Change |
|------|--------|
| `c_src/pyvrp/search/Exchange.h` | Added `!U->route()` guard, returns `{cost, cost < 0}` |
| `c_src/pyvrp/search/SwapTails.cpp` | Returns `{cost, cost < 0}` |
| `c_src/pyvrp/search/RelocateWithDepot.cpp` | Returns `{cost, cost < 0}` |
| `c_src/pyvrp/search/SwapStar.cpp` | Returns `{cost, cost < 0}` |
| `c_src/pyvrp/search/LocalSearch.{h,cpp}` | Major rewrite: removed 4 inline methods, added `applyUnaryOps`, `ensureStructuralFeasibility`, refactored `search()` loop and dispatch |
| `c_src/pyvrp/search/Solution.cpp` | Absorbed `insertCost` from primitives |
| `c_src/pyvrp/search/PerturbationManager.cpp` | Removed unused `#include "primitives.h"` |
| `c_src/ex_vrp_nif.cpp` | Added operator resources with `supports<Op>(data)` registration, removed primitive NIFs |
| `Makefile` | Removed `primitives.cpp`, added 4 new .cpp files |
| `lib/ex_vrp/native.ex` | Removed `insert_cost`, `remove_cost`, `inplace_cost` NIFs |

**Files removed**: `primitives.{h,cpp}`, `test/primitives_test.exs`

**Verified**: 947/947 tests pass (13 primitives tests removed), benchmarks show no quality regression (most instances faster).

---

## Phase 3: Remove SwapRoutes/SwapStar — Size: M ✅ DONE

**Goal**: Remove route operators deleted upstream and all route operator infrastructure from LocalSearch.

**What changed**:

- Deleted `SwapRoutes.{h,cpp}` and `SwapStar.{h,cpp}`
- Removed all route operator infrastructure from `LocalSearch.{h,cpp}`: `routeOps` vector, `lastTestedRoutes`, `applyRouteOps()`, `intensify()` (both private search loop and public method), `addRouteOperator()`, `routeOperators()`
- Simplified `operator()` — no longer runs search→intensify loop, just calls `search()` directly
- Removed `SwapStarResource`, `SwapRoutesResource` structs and all associated NIFs from `ex_vrp_nif.cpp`
- Removed `reconcile_route_ownership` overload for `SearchRouteResource` (dead code after NIF removal)
- Removed route_operators parsing from `local_search_with_operators_nif` and `local_search_stats_nif`
- Removed SwapRoutes auto-registration from `LocalSearchResource` constructor

**Files modified**:
| File | Change |
|------|--------|
| `c_src/pyvrp/search/LocalSearch.{h,cpp}` | Major rewrite: removed route operator infrastructure, simplified `operator()` |
| `c_src/ex_vrp_nif.cpp` | Removed includes, resource structs, 6 NIF functions, FINE_RESOURCE macros, route_ops parsing |
| `Makefile` | Removed `SwapRoutes.cpp`, `SwapStar.cpp` |
| `lib/ex_vrp/native.ex` | Removed 6 NIF declarations (create/evaluate/apply for SwapStar and SwapRoutes), removed `:route_operators` docs |
| `test/route_operators_test.exs` | Removed SwapStar and SwapRoutes test sections; renamed to SwapTails-focused test file |
| `test/local_search_test.exs` | Removed tests referencing `:swap_star`/`:swap_routes` route operators, cleaned up `route_operators: []` remnants |

**Files removed**: `SwapStar.{h,cpp}`, `SwapRoutes.{h,cpp}`

**Divergences from upstream plan**: Bug fixes #998 and #1045 were not ported — `ensureStructuralFeasibility()` was already added in Phase 2, and #998 (random optional client insertion) requires further investigation.

**Verified**: 926/926 tests pass (21 removed), benchmarks show no quality regression.

---

## Phase 4: Move Neighbourhood to C++ — Size: M ✅ DONE

**Goal**: Replace inline `build_neighbours()` in NIF file with proper C++ files matching upstream structure.

**What changed**:

- Extracted ~200-line `build_neighbours()` from `ex_vrp_nif.cpp` into `neighbourhood.{h,cpp}` under `pyvrp::search` namespace
- Added `NeighbourhoodParams` struct with `weightWaitTime` (default 0.2), `numNeighbours` (default 60), `symmetricProximity` (default true)
- `weightTimeWarp` hardcoded to 1.0 inside implementation (matches upstream — not a param)
- Replaced all 5 `build_neighbours(problem_data)` call sites with `pyvrp::search::computeNeighbours(problem_data)`

**New files created**:
| File | Purpose |
|------|---------|
| `c_src/pyvrp/search/neighbourhood.h` | `NeighbourhoodParams` struct + `computeNeighbours()` declaration |
| `c_src/pyvrp/search/neighbourhood.cpp` | Algorithm moved from `ex_vrp_nif.cpp` |

**Files modified**:
| File | Change |
|------|--------|
| `c_src/ex_vrp_nif.cpp` | Removed `build_neighbours()`, added `#include`, replaced 5 call sites |
| `Makefile` | Added `neighbourhood.cpp` to `PYVRP_SEARCH_SRC` |

**Divergences from upstream**: Our default `numNeighbours` is 60 (upstream uses 50) to maintain backward compatibility. Elixir `neighbourhood.ex` kept as reference implementation.

**Verified**: 923/923 tests pass, benchmarks show no quality regression.

---

## Phase 5: Data Model Modernization — Size: M ✅ DONE

**Goal**: Activity type system, remove centroid, remove `location()` accessor, add `client()`/`depot()` accessors, logging stub.

**What changed**:

- Added `client(size_t)` and `depot(size_t)` inline accessors to `ProblemData.h` matching upstream API
- Removed `Location` union, `location()` method, `centroid_` member, `centroid()` method from ProblemData
- Replaced all ~40 `data.location(idx)` call sites across 14 C++ files with `data.client(idx - data.numDepots())` or `data.depot(idx)` as appropriate
- Removed `problem_data_centroid_nif` from C++ and Elixir
- Created Activity type system, PiecewiseLinearFunction, and logging stub

**New files created**:
| File | Purpose |
|------|---------|
| `c_src/pyvrp/Activity.{h,cpp}` | Activity type system with DEPOT/CLIENT enum |
| `c_src/pyvrp/PiecewiseLinearFunction.h` | Header-only template class (from upstream) |
| `c_src/pyvrp/logging.h` | No-op logging macros stub (avoids spdlog dependency) |

**Files modified**:
| File | Change |
|------|--------|
| `c_src/pyvrp/ProblemData.{h,cpp}` | Added `client()`/`depot()` accessors, removed `Location` union, `location()`, `centroid_`, `centroid()` |
| `c_src/pyvrp/Route.cpp` | `location()` → `client()`/`depot()` |
| `c_src/pyvrp/Trip.cpp` | `location()` → `client()` |
| `c_src/pyvrp/Solution.cpp` | `location()` → `client()` |
| `c_src/pyvrp/bindings.cpp` | Removed ProblemData centroid binding |
| `c_src/pyvrp/search/LocalSearch.cpp` | `location()` → `client()`/`depot()` (6 sites) |
| `c_src/pyvrp/search/Route.{h,cpp}` | `location()` → `client()`/`depot()`, inline centroid computation replacing `data.centroid()` |
| `c_src/pyvrp/search/Solution.cpp` | `location()` → `client()`/`depot()` (6 sites) |
| `c_src/pyvrp/search/RelocateWithDepot.cpp` | `location()` → `depot()` (5 sites) |
| `c_src/pyvrp/search/RemoveOptional.cpp` | `location()` → `client()` (2 sites) |
| `c_src/pyvrp/search/ReplaceOptional.cpp` | `location()` → `client()` (3 sites) |
| `c_src/pyvrp/search/ReplaceGroup.cpp` | `location()` → `client()` (3 sites) |
| `c_src/pyvrp/search/RemoveAdjacentDepot.cpp` | `location()` → `client()` (1 site) |
| `c_src/pyvrp/search/ClientSegment.h` | `location()` → `client()` (2 sites) |
| `c_src/ex_vrp_nif.cpp` | Removed `problem_data_centroid_nif` |
| `lib/ex_vrp/native.ex` | Removed `problem_data_centroid_nif` from `@nifs` and function stub |
| `Makefile` | Added `Activity.cpp` to `PYVRP_CORE_SRC` |
| `test/problem_data_test.exs` | Removed centroid test |

**Divergences from upstream**: Trip/Route/search::Route centroids kept (they compute route-level centroids, not ProblemData-level). `solution_route_centroid` and `search_route_centroid_nif` NIFs kept. `route_centroid/2` in `solution.ex` kept (Zelo dependency — uses route centroid, not ProblemData centroid).

**Verified**: 923/923 tests pass, zero compilation warnings.

---

## Phase 6: EPyVRP-Inspired Algorithmic Improvements — Size: XL

**Goal**: Parallel Island ILS, diversified initialization, two-stage optimization. Pure Elixir — no C++ changes.

**Inspired by** EPyVRP's competition-winning approach, implemented from scratch using standard metaheuristic techniques.

**New Elixir files**:

| File                          | Purpose                                                                                                                |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `lib/ex_vrp/island_solver.ex` | Parallel Island ILS — launch N ILS processes with diverse params, periodic best-solution migration via message passing |
| `lib/ex_vrp/initializers.ex`  | Constructive heuristics: nearest-neighbor, sweep, time-window-aware, random insertion                                  |

**Modified Elixir files**:

| File                                  | Change                                                            |
| ------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `lib/ex_vrp/solver.ex`                | Add `strategy: :single                                            | :island`option,`num_islands:` option, two-stage support (Phase 1: minimize vehicles → Phase 2: minimize distance with elite seeding) |
| `lib/ex_vrp/iterated_local_search.ex` | Accept initial solution as parameter, add migration callback hook |

**Island Model design**:

- Each island: separate `Task.async` with its own ILS params (vary `max_no_improvement`, `history_size`, penalty params)
- Migration: every M iterations, best solution shared via message passing
- Quarantine: minimum K iterations before accepting migration
- Final result: best feasible solution across all islands
- NIF safety: Fine resources are reference-counted shared_ptrs — safe across BEAM processes

**Tests**: `test/island_solver_test.exs`, `test/initializers_test.exs`. Benchmark single vs island on Zelo-scale problems.

**Risk**: LOW (pure Elixir, additive). Watch for dirty scheduler contention with many islands.

---

## Verification Strategy

After each phase:

1. `mix compile --warnings-as-errors`
2. `mix test --include nif_required` — full test suite
3. `mix benchmark --instances ok_small,rc208,e_n22_k4` — regression check
4. For Zelo integration: update dep, run planner test suite

## Notes

- **sephianl/PyVRP fork**: Should be synced with upstream as a separate effort, or abandoned in favor of tracking upstream directly in ex_vrp's `c_src/`
- **Upstream tracking**: After this sync, consider a process for periodic upstream pulls (tag-based diffing)
- **SameVehicleGroup**: Ex_vrp extension not in upstream — must be maintained as a local divergence in LocalSearch.cpp

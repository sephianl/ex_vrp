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

## Phase 2: New Operators + Remove Primitives — Size: L

**Goal**: Add 5 new operators that replace the inline custom logic in LocalSearch.cpp. Remove primitives.h/cpp.

**New C++ files** (copy from upstream `pyvrp/cpp/search/`):
| File | Type | Replaces |
|------|------|----------|
| `InsertOptional.{h,cpp}` | BinaryOperator | inline `applyOptionalClientMoves` (insert) |
| `RemoveOptional.{h,cpp}` | UnaryOperator | inline `applyOptionalClientMoves` (remove) |
| `ReplaceOptional.{h,cpp}` | BinaryOperator | inline optional swap logic |
| `ReplaceGroup.{h,cpp}` | UnaryOperator | inline `applyGroupMoves` |
| `RemoveAdjacentDepot.{h,cpp}` | UnaryOperator | inline `applyDepotRemovalMove` |
| `ClientSegment.h` | Segment type | anonymous class in primitives.cpp |
| `DepotSegment.h` | Segment type | new |

**C++ files to remove**:

- `c_src/pyvrp/search/primitives.{h,cpp}`

**C++ files to modify**:
| File | Change |
|------|--------|
| `c_src/pyvrp/search/LocalSearch.{h,cpp}` | Remove all inline optional/group/depot logic. Search loop simplifies to: iterate clients → `applyUnaryOps(U)` → for each neighbour V: `applyBinaryOps(U, V)`. Keep `wouldViolateSameVehicle` in `applyBinaryOps` as ex_vrp extension |
| `c_src/ex_vrp_nif.cpp` | Add includes + resources for new operators. Update `LocalSearchResource` to use `supports<Op>(data)` for conditional registration. Remove primitives NIFs |
| `Makefile` | Remove `primitives.cpp`, add 5 new .cpp files |

**Elixir changes**:

- `lib/ex_vrp/native.ex`: Remove `insert_cost`, `remove_cost`, `inplace_cost` NIFs

**SameVehicleGroup preservation**: Keep `wouldViolateSameVehicle` check in `applyBinaryOps` — this is an ex_vrp extension not present in upstream.

**Tests**: Existing prize-collecting, client group, relocate-with-depot, same-vehicle-group tests must pass. Add per-operator unit tests. Update `test/primitives_test.exs`.

**Risk**: MEDIUM-HIGH — behavioral edge cases in operator interaction. Mitigate with targeted regression tests on Zelo-like problem structures before removing inline logic.

---

## Phase 3: Remove SwapRoutes/SwapStar + Bug Fixes — Size: M

**Goal**: Remove route operators deleted upstream. Add `ensureStructuralFeasibility()`. Port bug fixes #998 and #1045.

**C++ files to remove**:

- `c_src/pyvrp/search/SwapRoutes.{h,cpp}`
- `c_src/pyvrp/search/SwapStar.{h,cpp}`

**C++ files to modify**:
| File | Change |
|------|--------|
| `c_src/pyvrp/search/LocalSearch.{h,cpp}` | Remove route operator infrastructure. Add `ensureStructuralFeasibility()` call after perturbation (fixes #1045). Port #998 randomness in initial solution for optional clients |
| `c_src/ex_vrp_nif.cpp` | Remove SwapStar/SwapRoutes resources, NIFs, includes |
| `Makefile` | Remove `SwapRoutes.cpp`, `SwapStar.cpp` |

**Elixir changes**:

- `lib/ex_vrp/native.ex`: Remove SwapStar/SwapRoutes NIFs
- Remove/update `test/route_operators_test.exs`

**Tests**: Run full suite + benchmarks. Watch for quality regression on prize-collecting instances.

**Risk**: MEDIUM — route operators may have been helping on some problem types. The new operators from Phase 2 should compensate.

---

## Phase 4: Move Neighbourhood to C++ — Size: M

**Goal**: Replace Elixir Nx neighbourhood computation with upstream's C++ implementation.

_Can run in parallel with Phase 5 after Phase 3._

**New C++ files** (copy from upstream):

- `c_src/pyvrp/search/neighbourhood.{h,cpp}`

**C++ files to modify**:
| File | Change |
|------|--------|
| `c_src/ex_vrp_nif.cpp` | Replace existing `build_neighbours()` with call to `pyvrp::search::computeNeighbours()`. Optionally expose as NIF |
| `Makefile` | Add `neighbourhood.cpp` |

**Elixir changes**:

- `lib/ex_vrp/neighbourhood.ex`: Simplify to delegate to C++ NIF, or keep as reference implementation
- `lib/ex_vrp/neighbourhood_params.ex`: Verify parity with upstream's `NeighbourhoodParams`

**Tests**: Compare outputs between Nx and C++ implementations. Benchmark speedup.

**Risk**: LOW — well-defined algorithm, testable.

---

## Phase 5: Data Model Modernization — Size: M

**Goal**: Activity type system, remove centroid, remove `location()` accessor, logging stub.

_Can run in parallel with Phase 4 after Phase 3._

**New C++ files**:

- `c_src/pyvrp/Activity.{h,cpp}` — copy from upstream
- `c_src/pyvrp/PiecewiseLinearFunction.h` — copy from upstream (header-only)
- `c_src/pyvrp/logging.h` — create stub with no-op macros (avoid spdlog dependency in NIF context)

**C++ files to modify**:
| File | Change |
|------|--------|
| `c_src/pyvrp/ProblemData.{h,cpp}` | Remove `centroid_`, `centroid()`, `Location` union, `location()` method. Add `client()`/`depot()` accessors matching upstream |
| `c_src/pyvrp/Solution.{h,cpp}` | Update if ScheduledVisit changed to class |
| `c_src/ex_vrp_nif.cpp` | Remove `problem_data_centroid_nif`. Update all `data.location()` calls to `data.client()` / `data.depot()` (mechanical but widespread) |
| `Makefile` | Add `Activity.cpp` |

**Elixir changes**:

- `lib/ex_vrp/native.ex`: Remove `problem_data_centroid_nif`
- `lib/ex_vrp/solution.ex`: Remove or stub `route_centroid/2` (Zelo uses this — check usage before removing)

**Risk**: MEDIUM — `location()` removal is widespread. Grep all call sites first. Centroid removal may need Zelo-side migration.

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

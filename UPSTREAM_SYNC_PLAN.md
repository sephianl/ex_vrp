# Upstream Sync — Phases 6, 7, 9 Implementation Plan

## Context

Phases 1-5 complete on `update-to-upstream`. This plan covers the remaining work: two bug fixes (Phase 6), CostEvaluator refactoring (Phase 7), and Island ILS (Phase 9). Phase 8 (Activity/Location) is deferred until PyVRP v0.14.0 ships (2026-04-01).

Execution order: Phase 6 -> Phase 7 -> Phase 9 (sequential, commit after each phase).

---

## Phase 6: Bug Fixes — Size: S

### Step 6.1: Fix #1045 — ReplaceOptional replacing group members

**File**: `c_src/pyvrp/search/ReplaceOptional.cpp`

**Current** (line 69):

```cpp
if (vData.required)
    continue;
```

**Change to**:

```cpp
if (vData.required || vData.group)
    continue;
```

**Why**: V (the target being replaced) could belong to a mutually exclusive group. ReplaceGroup would then reinsert it, creating an infinite cycle.

### Step 6.2: Fix #998 — Fallback insertion for optional clients

**File**: `c_src/pyvrp/search/LocalSearch.cpp`

**Add include** at top (after existing includes):

```cpp
#include "ClientSegment.h"
```

**After the existing fallback block** (after line 213's closing `}`), add:

```cpp
if (!U->route())
{
    auto &route = solution_.routes[0];
    if (!route.empty())
    {
        Cost insertionCost = 0;
        costEvaluator.deltaCost<true>(
            insertionCost,
            Route::Proposal(route.before(0),
                            ClientSegment(data, U->client()),
                            route.after(1)));
        if (insertionCost < 0)
        {
            route.insert(1, U);
            update(&route, &route);
            searchSpace_.markPromising(U);
        }
    }
}
```

**Why**: When starting from empty solution, neighbourhood is empty so `solution_.insert()` can't evaluate optional clients against neighbours. This fallback tries inserting at position 1 of the first non-empty route directly.

### Step 6.3: Verify

```bash
mix compile
mix test --include nif_required
mix benchmark --instances ok_small
```

### Step 6.4: Commit

---

## Phase 7: CostEvaluator Template Specialization — Size: M

**Goal**: Replace concept-constrained templates with explicit specializations. Breaks circular `#include "Solution.h"` dependency in CostEvaluator.h.

### Analysis of current call sites

| Call site                 | Type              | File                                                              |
| ------------------------- | ----------------- | ----------------------------------------------------------------- |
| `penalisedCost(solution)` | `pyvrp::Solution` | `c_src/ex_vrp_nif.cpp:2220`                                       |
| `cost(solution)`          | `pyvrp::Solution` | `c_src/ex_vrp_nif.cpp:2234`                                       |
| `penalisedCost(*rU)`      | `search::Route`   | `c_src/pyvrp/search/LocalSearch.cpp:235-249` (debug asserts only) |

`penalisedCost`/`cost` are **never** called on `pyvrp::Route` or `search::Solution`.

### Step 7.1: Add `fixedVehicleCost_` to `pyvrp::Route`

**File**: `c_src/pyvrp/Route.h`

Add member after `reloadCost_` (line 127):

```cpp
Cost fixedVehicleCost_ = 0;  // Fixed cost of the vehicle type
```

Add public getter after `reloadCost()` (after line 291):

```cpp
[[nodiscard]] Cost fixedVehicleCost() const;
```

**File**: `c_src/pyvrp/Route.cpp`

In constructor `Route(ProblemData const &data, Trips trips, size_t vehType)`, after line 216 (`endDepot_ = vehData.endDepot;`), add:

```cpp
fixedVehicleCost_ = vehData.fixedCost;
```

Add getter implementation after `reloadCost()`:

```cpp
Cost Route::fixedVehicleCost() const { return fixedVehicleCost_; }
```

Update the raw constructor (line 310+) to accept and store `fixedVehicleCost_`. This also requires updating all callers of this constructor (serialization code in NIFs).

**File**: `c_src/pyvrp/Solution.cpp`

In `evaluate()` (line 41), change:

```cpp
fixedVehicleCost_ += data.vehicleType(route.vehicleType()).fixedCost;
```

to:

```cpp
fixedVehicleCost_ += route.fixedVehicleCost();
```

### Step 7.2: Refactor CostEvaluator.h

**File**: `c_src/pyvrp/CostEvaluator.h`

1. **Remove** `#include "Solution.h"` (line 6)
2. **Remove** `CostEvaluatable` concept (lines 18-28)
3. **Remove** `PrizeCostEvaluatable` concept (lines 33-36)
4. **Keep** `DeltaCostEvaluatable` concept (lines 40-46) — still used by `deltaCost`
5. **Change** `penalisedCost` declaration (line 122-123) from:
   ```cpp
   template <CostEvaluatable T>
   [[nodiscard]] Cost penalisedCost(T const &arg) const;
   ```
   to:
   ```cpp
   template <typename T>
   [[nodiscard]] Cost penalisedCost(T const &arg) const;
   ```
6. **Change** `cost` declaration (line 161) similarly to `template <typename T>`
7. **Remove** the inline definitions of `penalisedCost` (lines 237-257) and `cost` (lines 259-265) — these move to specializations

### Step 7.3: Add specialization for `pyvrp::Route`

**Simplest approach** (matching upstream pattern):

- Declare specializations in CostEvaluator.h using forward declarations
- Define specializations in the respective .cpp files

**File**: `c_src/pyvrp/CostEvaluator.h` — after the class definition, add forward-declared specializations:

```cpp
// Forward declarations for types used in specializations
class Route;
class Solution;
namespace search { class Route; }

// Explicit specialization declarations
template <> Cost CostEvaluator::penalisedCost(Route const &) const;
template <> Cost CostEvaluator::cost(Route const &) const;
template <> Cost CostEvaluator::penalisedCost(Solution const &) const;
template <> Cost CostEvaluator::cost(Solution const &) const;
template <> Cost CostEvaluator::penalisedCost(search::Route const &) const;
template <> Cost CostEvaluator::cost(search::Route const &) const;
```

**File**: `c_src/pyvrp/Route.cpp` — add at bottom:

```cpp
#include "CostEvaluator.h"

template <>
Cost CostEvaluator::penalisedCost(Route const &route) const
{
    if (route.empty())
        return 0;

    return route.distanceCost() + route.durationCost() + route.fixedVehicleCost()
           + route.reloadCost() + excessLoadPenalties(route.excessLoad())
           + twPenalty(route.timeWarp()) + distPenalty(route.excessDistance(), 0);
}

template <>
Cost CostEvaluator::cost(Route const &route) const
{
    return route.isFeasible() ? penalisedCost(route)
                              : std::numeric_limits<Cost>::max();
}
```

**File**: `c_src/pyvrp/Solution.cpp` — add at bottom:

```cpp
#include "CostEvaluator.h"

template <>
Cost CostEvaluator::penalisedCost(Solution const &sol) const
{
    if (sol.empty())
        return sol.uncollectedPrizes();

    Cost cost = sol.uncollectedPrizes();
    for (auto const &route : sol.routes())
        cost += penalisedCost(route);
    return cost;
}

template <>
Cost CostEvaluator::cost(Solution const &sol) const
{
    return sol.isFeasible() ? penalisedCost(sol)
                            : std::numeric_limits<Cost>::max();
}
```

**File**: `c_src/pyvrp/search/Route.cpp` — add at bottom:

```cpp
#include "../CostEvaluator.h"

template <>
pyvrp::Cost pyvrp::CostEvaluator::penalisedCost(search::Route const &route) const
{
    if (route.empty())
        return 0;

    return route.distanceCost() + route.durationCost() + route.fixedVehicleCost()
           + route.reloadCost() + excessLoadPenalties(route.excessLoad())
           + twPenalty(route.timeWarp()) + distPenalty(route.excessDistance(), 0);
}

template <>
pyvrp::Cost pyvrp::CostEvaluator::cost(search::Route const &route) const
{
    return route.isFeasible() ? penalisedCost(route)
                              : std::numeric_limits<Cost>::max();
}
```

### Step 7.4: Handle include ordering

The main challenge: `CostEvaluator.h` currently includes `Solution.h`. Removing it means files that use both must include them in the right order. The `deltaCost` templates still work via the `DeltaCostEvaluatable` concept which only needs `search::Route` types (already available through `search/Route.h`).

Files to check/update includes:

- `c_src/ex_vrp_nif.cpp` — needs both `CostEvaluator.h` and `Solution.h`
- `c_src/pyvrp/search/LocalSearch.cpp` — includes `LocalSearch.h` which chains to `CostEvaluator.h`
- `c_src/pyvrp/bindings.cpp` — Python bindings, not used but should compile

### Step 7.5: Update raw Route constructor

The raw constructor in `Route.h` (line 349+) and `Route.cpp` (line 310+) needs `fixedVehicleCost` parameter added. Check if NIFs use this constructor for deserialization.

### Step 7.6: Verify

```bash
mix compile --warnings-as-errors
mix test --include nif_required
mix benchmark
```

### Step 7.7: Commit

---

## Phase 9: Island ILS — Size: XL (Pure Elixir)

**Goal**: Parallel Island ILS using BEAM processes for better solution quality on multi-core.

### Step 9.1: Create `lib/ex_vrp/island_solver.ex` — Orchestrator

```elixir
defmodule ExVrp.IslandSolver do
  @moduledoc """
  Parallel Island-based ILS solver using BEAM processes.

  Each island runs an independent ILS with:
  - Its own LocalSearch resource (independent RNG)
  - Its own PenaltyManager with variant parameters
  - Its own LAHC history buffer

  Islands periodically exchange best solutions via message passing.
  """
end
```

**Key functions**:

1. `solve(problem_data, stop_fn, opts)` — main entry point
   - Determine `num_islands` (default `System.schedulers_online()`)
   - Generate island configs (parameter diversity table)
   - Front-load all LocalSearch creation (expensive O(n^2) neighbour computation)
   - Spawn island processes
   - Run orchestrator receive loop for migration
   - Collect results, return best

2. `island_configs(num_islands, base_params, seed)` — generate per-island params
   - Cycles through the 4 diversity profiles (baseline, aggressive, conservative, explorer)
   - Each gets a unique seed derived from base seed

3. `run_island(config, problem_data, local_search, stop_fn)` — island entry point
   - Create PenaltyManager with island-specific params
   - Create initial solution (empty -> local search, like current Solver)
   - Run ILS.run with migration callbacks
   - Send final result to orchestrator

4. `orchestrator_loop(islands, global_best, global_best_cost)` — migration coordination
   - Receive `{:island_best, pid, solution, cost}` messages
   - Update global best if improved
   - Broadcast `{:migration, solution}` to all islands
   - Monitor island processes for completion

### Step 9.2: Modify `lib/ex_vrp/iterated_local_search.ex` — Migration support

Add to ILS state (new optional fields, backward compatible):

```elixir
on_migration: nil,        # fn() -> solution_ref | nil
send_migration: nil,      # fn(solution_ref) -> :ok
migration_interval: 1000, # check/send every N iterations
migration_quarantine: 500, # min iterations between accepting migrations
last_migration: 0         # iteration of last accepted migration
```

Add two new pipeline steps in `iterate/2`:

1. `maybe_accept_migration/1` — every `migration_interval` iterations, call `on_migration.()` to check for incoming solution. Accept if quarantine elapsed and cost improves current.
2. `maybe_send_migration/1` — every `migration_interval` iterations, call `send_migration.(best)`.

**Migration acceptance rule**: Replace `current` (not `best`) to avoid premature convergence. Only accept if received solution's penalised cost < current cost.

### Step 9.3: Modify `lib/ex_vrp/solver.ex` — Add island strategy

Add to `@type solve_opts`:

```elixir
strategy: :single | :island,
num_islands: pos_integer()
```

In `solve/2`, branch on strategy:

- `:single` (default) — current behavior, unchanged
- `:island` — delegate to `IslandSolver.solve/3`

### Step 9.4: Create `lib/ex_vrp/initializers.ex` — Diversified initial solutions

Actually, for v1, all islands start from empty -> local search (current behavior) with different seeds. This already provides diversity via the random perturbation in LocalSearch. Defer fancy initializers (nearest-neighbor, sweep, etc.) to a follow-up.

**Skip this file for now** — not needed for MVP island solver.

### Step 9.5: Island parameter diversity

Encode the diversity table as a function:

```elixir
@island_profiles [
  # {max_no_improvement, history_size, penalty_increase, penalty_decrease}
  {50_000, 500, 1.25, 0.85},   # baseline
  {20_000, 200, 1.5, 0.7},     # aggressive
  {100_000, 1000, 1.1, 0.95},  # conservative
  {30_000, 300, 1.3, 0.8}      # explorer
]
```

Islands beyond 4 cycle through these profiles.

### Step 9.6: Tests

**File**: `test/island_solver_test.exs`

- Basic solve with 2 islands produces valid result
- Island solver respects max_runtime
- Result struct matches single solver interface
- Island solver with 1 island ~ single solver behavior

### Step 9.7: Verify

```bash
mix test --include nif_required
mix benchmark   # compare single vs island
```

### Step 9.8: Commit

---

## Risk Notes

**Phase 6**: Low risk. One-liner fix + 15-line fallback. Both are defensive checks.

**Phase 7**: Medium risk. Template specialization ordering is tricky. Main concern: ensuring the forward declarations in CostEvaluator.h work with the namespace structure (`pyvrp::search::Route` vs `pyvrp::Route`). If include ordering gets messy, fallback is to keep the inline template but just add `fixedVehicleCost()` to `pyvrp::Route` and skip the rest.

**Phase 9**: Low risk to existing code (additive, new files + backward-compatible option). Main concern: dirty scheduler contention if too many islands. Default to `System.schedulers_online()` which matches BEAM best practice.

## Verification Checklist (After All Phases)

```bash
mix compile --warnings-as-errors
mix test --include nif_required
mix benchmark --instances ok_small
mix benchmark  # full suite
```

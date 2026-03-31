# SVG Crash Bug — 2026-03-31

## Problem

Any model with >~50 clients AND same-vehicle groups (SVGs) segfaults during initial solution construction (`LocalSearch::search` → `CostEvaluator::deltaCost`). Models without SVGs work fine at any size. Small models with SVGs (≤50 clients) also work fine.

**CRITICAL**: This bug was always present but masked by a cached `.so` binary in `_build/`. The previous session's findings in `SOLVER_FINDINGS_2026_03_30.md` were done with this cached binary and may be inaccurate — the C++ changes from that session may not have been active during testing. A clean rebuild (`rm -rf c_src/obj _build/dev/lib/ex_vrp/priv && mix compile`) always reproduces the crash.

**IMPORTANT**: Always do a clean C++ rebuild after any C++ change: `rm -rf c_src/obj _build/dev/lib/ex_vrp/priv && mix compile`. The Makefile cleans `.o` files after linking, so incremental rebuilds may not recompile changed files. Verify with a quick test before doing longer runs.

## Reproduction

```elixir
# This crashes (55 clients + SVG):
model = ExVrp.Model.new() |> ExVrp.Model.add_depot(x: 0, y: 0)
model = Enum.reduce(1..55, model, fn i, m ->
  ExVrp.Model.add_client(m, x: rem(i * 7, 100), y: rem(i * 13, 100),
    delivery: [1], required: true, prize: 150_000)
end)
model = ExVrp.Model.add_vehicle_type(model, num_available: 6, capacity: [50])
model = %{model | same_vehicle_groups: [%ExVrp.SameVehicleGroup{clients: [3, 10], name: ""}]}
{:ok, r} = ExVrp.solve(model, max_runtime: 1_000, seed: 42)  # SEGFAULT

# This works (same model, no SVG):
model_no_svg = %{model | same_vehicle_groups: []}
{:ok, r} = ExVrp.solve(model_no_svg, max_runtime: 1_000, seed: 42)  # OK

# This works (SVG but only 50 clients):
# ... build with 50 clients instead of 55 ... OK

# The 2026-03-30 benchmark (628 clients) also crashes with SVGs, works without:
data = File.read!("priv/benchmark_data/production/2026-03-30_5d6a2c58-7a27-4092-ae02-b1f5f1833dff_model.etf")
model = data |> Base.decode64!() |> :erlang.binary_to_term()
model_no_svg = %{model | same_vehicle_groups: []}
{:ok, r} = ExVrp.solve(model_no_svg, max_runtime: 3_000, seed: 42)  # OK
{:ok, r} = ExVrp.solve(model, max_runtime: 3_000, seed: 42)          # SEGFAULT
```

## Key facts

- Crashes at ALL optimization levels (O0, O1, O2, O3, with and without LTO)
- Both Clang 20 and GCC 15
- **AddressSanitizer does NOT detect any error** (ASAN+UBSan build runs fine, no errors!)
- Adding `.at()` bounds checking to `LoadSegment` constructor (the most likely OOB candidate) does NOT throw
- Stack trace always shows crash in `CostEvaluator::deltaCost` during Exchange operator evaluation
- The crash is NOT in any bcb9619-specific code — reverting ALL bcb9619 C++ changes (back to 8d86d6d and even further back to b9f8dc6) still crashes
- The crash IS specific to SVGs — removing `same_vehicle_groups` from any model fixes it
- The crash is size-dependent: ≤50 clients OK, ≥55 clients crash (boundary is fuzzy, not clean — e.g. n=65 once passed while n=60 crashed)
- SVG client indices are all valid (verified: within [numDepots, numLocations) range)
- The `ProblemData::validate()` function passes without errors

## What's NOT the cause (individually disabled/reverted, crash persists)

- `insertConstrainedFirst` — commented out the call, still crashes
- `applySameVehicleRepair` — commented out the call, still crashes
- `wouldViolateSameVehicle` — reverted to pre-bcb9619, still crashes
- `wouldViolateForbidden` / `isHardToPlace` — reverted, still crashes
- `improveWithMultiTrip` — commented out the call, still crashes
- P27 phantom dimension fix — original ETF also crashes
- `isReachable` in search/Solution.cpp — reverted, still crashes
- SVG penalty in CostEvaluator.h — reverted, still crashes
- `LoadSegment` bounds — added `.at()` checks, no OOB detected

## The only SVG-touching code that remains after all reverts

When ALL bcb9619 changes are reverted, the code that remains SVG-specific is:

1. **`ProblemData` constructor** — stores `sameVehicleGroups_` (moved in, no issue)
2. **`ProblemData::validate()`** — iterates SVG groups, validates indices (passes OK)
3. **`pyvrp::Solution` constructor** — computes `numSVGViolations_` and `isGroupFeas_` at lines 291-342 of Solution.cpp. This accesses `clientRoute[client]` and `data.vehicleType(vehType).name`
4. **`LocalSearch` constructor** — builds `clientToSameVehicleGroups_` lookup (line 1018-1025)
5. **`LocalSearch::wouldViolateSameVehicle()`** — checks `clientToSameVehicleGroups_[U->client()]` and accesses `data.vehicleType().name` with `strcmp`

Since disabling `wouldViolateSameVehicle` (by reverting bcb9619) still crashes, and disabling `insertConstrainedFirst`/`applySameVehicleRepair` (which are the callers) still crashes, the issue is likely in items 3 or 4 — code that runs just from SVGs EXISTING in the ProblemData.

## Strongest hypothesis: uninitialized memory

ASAN doesn't catch: heap OOB, use-after-free, stack OOB, double-free.
UBSan doesn't catch: signed overflow, null deref, alignment, shift errors.
`.at()` doesn't catch: LoadSegment dimension OOB.

What **none of these** catch: **uninitialized memory reads**. That requires MemorySanitizer (`-fsanitize=memory`), which can't be LD_PRELOADed — it needs the entire runtime compiled with MSan.

The fuzzy size boundary (sometimes 55 crashes, sometimes 65 passes) is classic uninitialized memory behavior — depends on what value happens to be in that memory location.

### Where could uninitialized memory come from?

The `LocalSearch` constructor initializes `clientToSameVehicleGroups_` as a `vector<vector<size_t>>(numLocations)`. This creates `numLocations` empty inner vectors. For locations NOT in any SVG, the inner vector stays empty (size 0). For SVG members, it has group indices pushed.

The `search::Solution` class has a `nodes` vector of `Route::Node`. Each node is initialized in `Solution::load()`. If any field of `Route::Node` is not initialized (e.g., the `trip_` field, or `route_` pointer), and SVG code paths read it...

### Specific suspect: `numSVGViolations_` in pyvrp::Solution

Line 63 of Solution.h: `size_t numSVGViolations_ = 0;` — this is initialized. But the SVG violation computation (Solution.cpp:291-342) accesses `clientRoute[client]` where `clientRoute` is built from `routes_`. If `routes_` has stale data... but `routes_` is built from the constructor argument.

## Tools available

- Valgrind is available via `nix shell nixpkgs#valgrind -c ...` but couldn't get it to wrap `mix run` (BEAM's launch script confuses it). A standalone C++ test binary would work.
- ASAN/UBSan work via `SANITIZE=1 mix compile` (Makefile supports it) + `LD_PRELOAD=$(clang++ -print-file-name=libclang_rt.asan-x86_64.so)`. ASAN build does NOT crash but also detects no errors.
- GDB can get stack traces from coredumps via `coredumpctl info` but can't step through BEAM interactively.

## Recommended investigation path

1. **Build a standalone C++ test** (no BEAM/NIF) that creates ProblemData with 55 clients + 1 SVG and runs `LocalSearch::search`. Link against the compiled object files. Run under valgrind.
2. **Try MemorySanitizer** if possible — this would catch uninitialized reads that ASAN misses.
3. **Add fprintf-based debugging** in `CostEvaluator::deltaCost` to print the route pointer, its size, and whether the proposal is valid before crashing.
4. **Check `Route::Node` initialization** — specifically look for any uninitialized fields that SVG code paths might read.

## Coredump stack trace (consistent across all crashes)

```
#0  CostEvaluator::deltaCost<true, false, Route::SegmentBefore, ClientSegment, Route::SegmentAfter>
        (ex_vrp_nif.so + 0x879e3)
#1  LocalSearch::search(CostEvaluator const&)
        (ex_vrp_nif.so + 0x6e5f6)
#2  LocalSearch::search(Solution const&, CostEvaluator const&, long)
        (ex_vrp_nif.so + 0x702bb)
#3  local_search_search_run_nif(...)
        (ex_vrp_nif.so + 0x474a6)
```

## Files changed in this session (uncommitted)

- `priv/benchmark_data/production/2026-03-30_*.etf` — P27 phantom dimension removed, base64-encoded
- `priv/benchmark_data/production/captured_1774622392_model.etf` — extracted from `%{model: model}` wrapper, base64-encoded
- `priv/benchmark_data/production/oban-966279_model.etf` etc — attempted fix by reversing client lists (may not be correct, needs re-verification after crash is fixed)

## Elixir changes prepared but untested (in git stash or reverted)

These were written to improve SVG feasibility consistency but couldn't be tested due to the crash:

1. **`ensureSVGCohesion()` + `insertConstrainedFirst()` after perturbation** — prevents perturbation from permanently splitting SVG members
2. **SVG partners added to distance-based neighbourhoods** — lets Exchange operators find SVG partners
3. **Bidirectional SVG repair** — tries both directions when reuniting split partners
4. **`num_seeds` option** — tries N initial constructions, picks best feasible
5. **Parallel solver with shared best** — seeds share feasible solutions via Agent
6. **SVG penalty increased to 1M** — stronger gradient toward SVG feasibility

These changes were reverted to isolate the crash. They should be re-applied after the crash is fixed.

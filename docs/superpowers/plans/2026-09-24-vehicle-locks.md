# Vehicle Locks (ex_vrp 0.13) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a model lock a client to one vehicle type with a price paid whenever any other vehicle type serves it, visible to every local-search move; carry trip boundaries through warm starts; drop the 0.12.2 perturbation guard; release 0.13.0.

**Architecture:** The lock rides the existing node-additive penalty channel. `ProblemData` gains a per-location optional lock (`vehicle type`, `price`); every place that asks "what does visiting location L cost on this route" (`cumPenalty` in the search route, `SegmentBetween` recompute, `ClientSegment`, the solution-side `Route` constructor) now asks with the route's vehicle type as well as its profile. `Solution` reports the lock share separately (`lockCost()`) while `penaltyCost()` keeps meaning "everything the penalty channel charged". Trip-aware warm starts let a host seed multi-trip routes as trips, and `solution_trips/1` reads them back so the 0.12.1 trim can run on multi-trip routes.

**Tech Stack:** C++20 (PyVRP-derived core in `c_src/ex_vrp`), Fine NIFs (`c_src/ex_vrp_nif.cpp`), Elixir wrapper (`lib/ex_vrp`), ExUnit.

**Spec:** The zelo plan `/home/jeroen/Documents/zelo/docs/superpowers/plans/2026-09-24-keep-docks-vehicle-locks.md`, section "Agreed requirements", plus Linear ZELO-4299 and ZELO-4306.

## Global Constraints

- One Zelo vehicle is one vehicle type (`num_available: 1`); a lock is therefore keyed by vehicle type index.
- A lock is soft: price in cost units (micro-euros in Zelo), non-negative, charged once per visit when the serving route's vehicle type differs from the locked one. A locked client that is not visited pays no lock price (its prize/required flag governs that).
- Depots cannot be locked.
- A model with no locks set must behave bit-for-bit as 0.12.2 minus the perturbation guard (same objective, same `penalty_cost`).
- Every search move's delta must equal the change in `Solution` cost: under `SANITIZE=1` (asserts on) `LocalSearch` checks `costAfter == costBefore + deltaCost`.
- After any C/C++ change: `EX_VRP_FORCE_BUILD=1 mix compile` (else the precompiled NIF is used and changes silently do nothing).
- Style: match surrounding code; PyVRP naming in C++, Elixir idioms in the wrapper.

## Review Focus

- Lock on a client in a mutually exclusive client group (disjunctive time windows): only the visited member pays, and validation accepts it — tested in Task 1 (validation) and Task 3 (search).
- A route served by an unlocked vehicle type whose profile equals the locked one's profile: `SegmentBetween` must still recompute (profile equal, vehicle type different) — tested in Task 3.
- Warm start containing a locked client on the wrong vehicle: the seed's cost includes the lock price and the search moves it — tested in Task 3.
- Warm start with trips whose reload depot is not in the vehicle type's `reload_depots`: rejected as structurally invalid with a warning and cold-start fallback, like other invalid starts — tested in Task 4.
- Lock referring to a vehicle type index out of range: `Model.validate/1` error, never a NIF crash — tested in Task 1.

---

### Task 1: Lock data in the model and ProblemData

**Files:**

- Modify: `lib/ex_vrp/model.ex` (struct field, `set_vehicle_locks/2`, validation next to `validate_penalties/2` at ~:724)
- Modify: `c_src/ex_vrp/ProblemData.h` (member next to `penalties_` at ~:696, accessor next to `penalty/2` at ~:846 and ~:964)
- Modify: `c_src/ex_vrp/ProblemData.cpp` (constructor, validation)
- Modify: `c_src/ex_vrp_nif.cpp` (decode `vehicle_locks` next to penalties at ~:1187 and ~:1324; pass to `ProblemData` at ~:1404)
- Test: `test/vehicle_lock_test.exs` (create)

**Interfaces:**

- Produces: `ExVrp.Model.set_vehicle_locks(model, [%{location: non_neg_integer(), vehicle_type: non_neg_integer(), price: non_neg_integer()}]) :: Model.t()`; model field `vehicle_locks: [map()]` (default `[]`).
- Produces (C++): `struct ProblemData::VehicleLock { size_t vehicleType; Cost price; }`; `Cost ProblemData::lockPenalty(size_t vehicleType, size_t location) const` — `price` when the location is locked to a different vehicle type, else `0`; `bool ProblemData::hasVehicleLocks() const`.

- [ ] **Step 1: Write the failing validation tests**

```elixir
defmodule ExVrp.VehicleLockTest do
  @moduledoc """
  Behavioural tests for vehicle locks: a client locked to one vehicle type pays
  a price whenever another vehicle type serves it. Soft, like the penalty
  channel it rides on.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model

  # One depot, two clients, two single-vehicle types.
  defp base_model do
    Model.new()
    |> Model.add_depot(tw_late: 1000)
    |> Model.add_client(delivery: [1], tw_late: 1000, required: false, prize: 1000)
    |> Model.add_client(delivery: [1], tw_late: 1000, required: false, prize: 1000)
    |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_distance_cost: 1)
    |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_distance_cost: 1)
    |> Model.set_distance_matrices([[[0, 10, 10], [10, 0, 10], [10, 10, 0]]])
    |> Model.set_duration_matrices([[[0, 10, 10], [10, 0, 10], [10, 10, 0]]])
  end

  describe "validation" do
    test "a model with locks on clients validates" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 0, price: 500}])

      assert :ok == Model.validate(model)
    end

    test "a lock on a depot is rejected" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 0, vehicle_type: 0, price: 500}])

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &(&1 =~ "lock"))
    end

    test "a lock naming a vehicle type that does not exist is rejected" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 7, price: 500}])

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &(&1 =~ "vehicle type"))
    end

    test "two locks on one client are rejected" do
      locks = [%{location: 1, vehicle_type: 0, price: 500}, %{location: 1, vehicle_type: 1, price: 500}]

      assert {:error, errors} = Model.validate(Model.set_vehicle_locks(base_model(), locks))
      assert Enum.any?(errors, &(&1 =~ "more than one lock"))
    end

    test "a negative price is rejected" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 0, price: -1}])

      assert {:error, _errors} = Model.validate(model)
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/vehicle_lock_test.exs`
Expected: FAIL — `Model.set_vehicle_locks/2` is undefined.

- [ ] **Step 3: Implement the Elixir side**

In `lib/ex_vrp/model.ex`: add `vehicle_locks: [map()]` to the `@type t` and `vehicle_locks: []` to the struct defaults (next to `penalties`). Add, after `set_penalties/2`:

```elixir
  @doc """
  Locks clients to vehicle types. A locked client pays `price` whenever a vehicle type other than
  `vehicle_type` serves it, and nothing when its own does or when it is not served at all.

  `location` is a location index in matrix order (depots first, then clients), as for
  `set_penalties/2`. At most one lock per client. Defaults to no locks.

  ## Example

      model
      |> ExVrp.Model.set_vehicle_locks([%{location: 3, vehicle_type: 0, price: 5_000}])
  """
  @spec set_vehicle_locks(t(), [%{location: non_neg_integer(), vehicle_type: non_neg_integer(), price: non_neg_integer()}]) ::
          t()
  def set_vehicle_locks(%__MODULE__{} = model, locks), do: %{model | vehicle_locks: locks}
```

Add `|> validate_vehicle_locks(model)` to the validation pipeline next to `validate_penalties(model)` (~:530), and:

```elixir
  defp validate_vehicle_locks(errors, %{vehicle_locks: []}), do: errors

  defp validate_vehicle_locks(errors, model) do
    num_depots = length(model.depots)
    num_locations = num_depots + length(model.clients)
    num_vehicle_types = length(model.vehicle_types)

    errors
    |> add_lock_errors(Enum.flat_map(model.vehicle_locks, &lock_errors(&1, num_depots, num_locations, num_vehicle_types)))
    |> add_lock_errors(duplicate_lock_errors(model.vehicle_locks))
  end

  defp lock_errors(%{location: loc, vehicle_type: vt, price: price}, num_depots, num_locations, num_vehicle_types) do
    [
      loc < num_depots && "vehicle lock on location #{loc}: depots cannot be locked",
      loc >= num_locations && "vehicle lock on location #{loc}: no such location",
      vt >= num_vehicle_types && "vehicle lock on location #{loc}: vehicle type #{vt} does not exist",
      (not is_integer(price) or price < 0) && "vehicle lock on location #{loc}: price must be a non-negative integer"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp duplicate_lock_errors(locks) do
    locks
    |> Enum.frequencies_by(& &1.location)
    |> Enum.filter(fn {_loc, count} -> count > 1 end)
    |> Enum.map(fn {loc, _count} -> "location #{loc} has more than one lock" end)
  end

  defp add_lock_errors(errors, new_errors), do: errors ++ new_errors
```

(Match the error accumulation shape `validate_penalties/2` uses; if it prepends, prepend.)

- [ ] **Step 4: Implement ProblemData and the NIF decode**

`ProblemData.h`, next to `penalties_`:

```cpp
    // Per-location vehicle lock: visiting a locked location on any vehicle
    // type other than the locked one costs the lock's price. Node-additive
    // like penalties_, but keyed by vehicle type rather than profile. Empty
    // when the model sets no locks.
    std::vector<std::optional<VehicleLock>> const locks_;
```

Public declarations (with the `penalty` accessors):

```cpp
    struct VehicleLock
    {
        size_t const vehicleType;
        Cost const price;
    };

    /**
     * Price charged for visiting ``location`` on ``vehicleType``: the lock's
     * price when the location is locked to another vehicle type, else zero.
     */
    [[nodiscard]] inline Cost lockPenalty(size_t vehicleType,
                                          size_t location) const;

    /**
     * Whether any location carries a vehicle lock.
     */
    [[nodiscard]] inline bool hasVehicleLocks() const;
```

Inline definitions (next to `ProblemData::penalty` ~:964):

```cpp
Cost ProblemData::lockPenalty(size_t vehicleType, size_t location) const
{
    if (locks_.empty())
        return 0;

    assert(location < locks_.size());
    auto const &lock = locks_[location];
    return lock && lock->vehicleType != vehicleType ? lock->price : 0;
}

bool ProblemData::hasVehicleLocks() const { return !locks_.empty(); }
```

Add a `std::vector<std::optional<VehicleLock>> locks = {}` constructor parameter after `allowed` in both the declaration and `ProblemData.cpp`; move it into `locks_`. In the constructor's validation, when `!locks_.empty()`: throw `std::invalid_argument` if `locks_.size() != numLocations()`, if any depot index holds a lock, or if a lock's `vehicleType >= numVehicleTypes()`.

`ex_vrp_nif.cpp`: fetch the optional `vehicle_locks` key the same way `penalties` is fetched (~:1187), and after the penalties decode (~:1356):

```cpp
    // Decode vehicle locks: a list of %{location, vehicle_type, price} maps,
    // spread into one optional lock per location. Empty means no locks.
    std::vector<std::optional<ProblemData::VehicleLock>> locks;
    if (has_locks)
    {
        unsigned num_locks;
        if (!enif_get_list_length(env, locks_term, &num_locks))
            throw std::invalid_argument("Expected list for vehicle_locks");

        if (num_locks > 0)
            locks.resize(num_locations);

        tail = locks_term;
        for (unsigned idx = 0; idx < num_locks; idx++)
        {
            enif_get_list_cell(env, tail, &head, &tail);

            auto const location = get_map_uint(env, head, "location");
            auto const vehicle_type = get_map_uint(env, head, "vehicle_type");
            auto const price = get_map_int64(env, head, "price");

            if (location >= num_locations || price < 0)
                throw std::invalid_argument("Invalid vehicle lock");

            locks[location] = ProblemData::VehicleLock{vehicle_type,
                                                       Cost(price)};
        }
    }
```

Use whatever map-field helpers the NIF already has for decoding client/vehicle-type maps (grep `enif_get_map_value` near the client decode and reuse its helper; add `get_map_uint`/`get_map_int64` only if none exist). Pass `std::move(locks)` as the last `ProblemData` argument (~:1412).

- [ ] **Step 5: Rebuild and run the tests**

Run: `EX_VRP_FORCE_BUILD=1 mix compile && mix test test/vehicle_lock_test.exs`
Expected: PASS (5 tests).

Also run: `mix test test/penalty_channel_test.exs test/model_test.exs test/problem_data_test.exs`
Expected: PASS — nothing that sets no locks changes.

- [ ] **Step 6: Commit**

```bash
git add lib/ex_vrp/model.ex c_src/ex_vrp/ProblemData.h c_src/ex_vrp/ProblemData.cpp c_src/ex_vrp_nif.cpp test/vehicle_lock_test.exs
git commit -m "Add vehicle locks to the model and ProblemData"
```

---

### Task 2: Charge locks in the solution's cost

**Files:**

- Modify: `c_src/ex_vrp/Route.cpp:292-315` (constructor sums penalties per visit), `c_src/ex_vrp/Route.h` (member + accessor), `c_src/ex_vrp/Solution.h:59,228-234`, `c_src/ex_vrp/Solution.cpp:43,121`
- Modify: `c_src/ex_vrp_nif.cpp` (`solution_lock_cost` next to `solution_penalty_cost` ~:2268), `lib/ex_vrp/native.ex`, `lib/ex_vrp/solution.ex`
- Test: `test/vehicle_lock_test.exs`

**Interfaces:**

- Consumes: `ProblemData::lockPenalty/2` (Task 1).
- Produces: `Route::lockCost()`, `Solution::lockCost()` (C++); `ExVrp.Solution.lock_cost(solution) :: non_neg_integer()`. `penaltyCost()` now includes the lock share (so the objective picks it up through the existing `penaltyCost()` term in `CostEvaluator.h:264`).

- [ ] **Step 1: Write the failing tests**

Append to `test/vehicle_lock_test.exs`:

```elixir
  describe "solution cost" do
    alias ExVrp.Solution
    alias ExVrp.Solver

    defp solve(model, initial_routes \\ nil) do
      Solver.solve(model,
        stop: ExVrp.StoppingCriteria.max_iterations(200),
        initial_routes: initial_routes
      )
    end

    test "a client served by its locked vehicle type pays nothing" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 0, price: 500}])

      {:ok, result} = solve(model, [[1, 2], []])

      assert Solution.lock_cost(result.best) == 0
    end

    test "a lock price is part of the solution's penalty cost" do
      locked = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 1, price: 5}])

      {:ok, result} = Solver.solve(locked, stop: ExVrp.StoppingCriteria.max_iterations(0), initial_routes: [[1, 2], []])

      assert Solution.lock_cost(result.best) == 5
      assert Solution.penalty_cost(result.best) == 5
    end

    test "a model without locks reports no lock cost" do
      {:ok, result} = solve(base_model())

      assert Solution.lock_cost(result.best) == 0
    end
  end
```

(The second test uses 0 iterations so the warm start is returned as is; if the solver's zero-iteration path does not return the seed, use `ExVrp.Solution` construction from routes the way `test/solution_test.exs` does and assert on that.)

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/vehicle_lock_test.exs`
Expected: FAIL — `Solution.lock_cost/1` undefined.

- [ ] **Step 3: Implement**

`Route.cpp` constructor, inside the per-client loop (after `penaltyCost_ += penalties[client];`):

```cpp
            auto const lock = data.lockPenalty(vehType, client);
            lockCost_ += lock;
            penaltyCost_ += lock;
```

`Route.h`: add `Cost lockCost_ = 0;  // Lock share of penaltyCost_` next to `penaltyCost_`, and `[[nodiscard]] Cost lockCost() const;` with `Cost Route::lockCost() const { return lockCost_; }` in `Route.cpp` next to `penaltyCost()` (:500).

`Solution.h`/`.cpp`: `Cost lockCost_ = 0;`, accumulate `lockCost_ += route.lockCost();` next to `penaltyCost_ += route.penaltyCost();` (:43), accessor `Cost Solution::lockCost() const { return lockCost_; }` with a doc comment: "The part of :meth:`~penalty_cost` charged by vehicle locks."

NIF, next to `solution_penalty_cost`:

```cpp
/**
 * Get the vehicle-lock share of the solution's penalty cost.
 */
int64_t
solution_lock_cost([[maybe_unused]] ErlNifEnv *env,
                   fine::ResourcePtr<SolutionResource> solution_resource)
{
    return static_cast<int64_t>(solution_resource->solution.lockCost());
}

FINE_NIF(solution_lock_cost, 0);
```

`native.ex`: add `solution_lock_cost: 1` to the NIF list and `def solution_lock_cost(_solution_ref), do: :erlang.nif_error(:nif_not_loaded)` with a spec. `solution.ex`: `def lock_cost(solution)` delegating the way `penalty_cost/1` does, with a `@doc` saying it is the lock share of `penalty_cost/1`.

- [ ] **Step 4: Rebuild and run**

Run: `EX_VRP_FORCE_BUILD=1 mix compile && mix test test/vehicle_lock_test.exs test/penalty_channel_test.exs test/solution_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add c_src lib test/vehicle_lock_test.exs
git commit -m "Charge vehicle locks in the solution's penalty cost"
```

---

### Task 3: Price locks inside every search move

**Files:**

- Modify: `c_src/ex_vrp/search/Route.h` (`Segment` concept :43-54; `SegmentAfter/Before/Between::penalty` declarations :286,:313,:342 and definitions ~:858-1011; `Proposal::penalty` :1442-1456)
- Modify: `c_src/ex_vrp/search/Route.cpp:241-252` (`cumPenalty` build)
- Modify: `c_src/ex_vrp/search/Segments.h:44` (`ClientSegment::penalty`), and any other segment type in `Segments.h` with a `penalty(size_t profile)` method
- Test: `test/vehicle_lock_test.exs`

**Interfaces:**

- Consumes: `ProblemData::lockPenalty/2` (Task 1).
- Produces: the `Segment` concept's penalty requirement becomes `arg.penalty(profile, vehicleType)`; every segment type implements `Cost penalty(size_t profile, size_t vehicleType) const`.

- [ ] **Step 1: Write the failing tests**

Append:

```elixir
  describe "locks under local search" do
    alias ExVrp.Solution
    alias ExVrp.Solver

    # A line of locations; vehicle type 0 starts at the far left, type 1 at the far right, both
    # at depot 0 for simplicity of the matrix but with a fixed cost difference per side. Every
    # odd client is locked to type 0, every even one to type 1. Without locks the solver
    # partitions by position; with a high price it must partition by lock instead.
    defp line_model(n, price) do
      locations = 0..n

      matrix = for i <- locations, do: for(j <- locations, do: abs(i - j) * 10)

      model =
        Enum.reduce(1..n, Model.new() |> Model.add_depot(tw_late: 100_000), fn _i, m ->
          Model.add_client(m, delivery: [1], tw_late: 100_000, required: true)
        end)
        |> Model.add_vehicle_type(num_available: 1, capacity: [n], unit_distance_cost: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [n], unit_distance_cost: 1)
        |> Model.set_distance_matrices([matrix])
        |> Model.set_duration_matrices([matrix])

      locks = for loc <- 1..n, do: %{location: loc, vehicle_type: rem(loc, 2), price: price}

      Model.set_vehicle_locks(model, locks)
    end

    test "a price above any routing gain puts every locked client on its vehicle type" do
      {:ok, result} = Solver.solve(line_model(12, 1_000_000), stop: ExVrp.StoppingCriteria.max_iterations(2_000))

      assert Solution.is_feasible(result.best)
      assert Solution.lock_cost(result.best) == 0
    end

    test "a zero price leaves the solver free to ignore the locks" do
      {:ok, result} = Solver.solve(line_model(12, 0), stop: ExVrp.StoppingCriteria.max_iterations(2_000))

      assert Solution.lock_cost(result.best) == 0
      assert Solution.num_clients(result.best) == 12
    end

    test "a warm start with every client on the wrong vehicle type is moved back" do
      n = 12
      wrong = [Enum.filter(1..n, &(rem(&1, 2) == 1)), Enum.filter(1..n, &(rem(&1, 2) == 0))]

      {:ok, result} =
        Solver.solve(line_model(n, 1_000_000),
          stop: ExVrp.StoppingCriteria.max_iterations(2_000),
          initial_routes: wrong
        )

      assert Solution.lock_cost(result.best) == 0
    end

    test "a vehicle type sharing the locked type's profile still pays the lock" do
      # Both vehicle types use profile 0, so SegmentBetween cannot short-circuit on profile alone.
      model = line_model(4, 1_000)
      {:ok, result} = Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(0), initial_routes: [[2, 4], [1, 3]])

      assert Solution.lock_cost(result.best) == 4 * 1_000
    end
  end
```

- [ ] **Step 2: Run to verify the first and third fail**

Run: `EX_VRP_FORCE_BUILD=1 mix compile && mix test test/vehicle_lock_test.exs`
Expected: "a price above any routing gain" and "a warm start ... is moved back" FAIL (the search does not see the lock, so it partitions by position); the others may pass already via Task 2.

- [ ] **Step 3: Implement**

`Segment` concept (`search/Route.h:43`): replace `{ arg.penalty(profile) } -> std::convertible_to<Cost>;` with `{ arg.penalty(profile, vehicleType) } -> std::convertible_to<Cost>;` and add `size_t vehicleType` to the `requires(...)` parameter list.

`search/Route.cpp` `cumPenalty` build:

```cpp
    // Penalties. Note the differing shapes: cumDist is edge-additive and
    // inclusive of length nodes.size(), whereas cumPenalty is node-additive
    // and an exclusive prefix of length nodes.size() + 1. Depot penalties and
    // locks are zero, so including depots in the sum is harmless. The prefix
    // is for this route's own profile and vehicle type; segments evaluated
    // for another route recompute (see SegmentBetween::penalty).
    auto const &penalties = data.penalties(profile());

    cumPenalty.resize(nodes.size() + 1);
    cumPenalty[0] = 0;
    for (size_t idx = 0; idx != nodes.size(); ++idx)
        cumPenalty[idx + 1]
            = cumPenalty[idx] + penalties[visits[idx]]
              + data.lockPenalty(vehicleType(), visits[idx]);
```

`SegmentAfter::penalty` / `SegmentBefore::penalty`: change the signature to `(size_t profile, size_t vehicleType)`, keep them same-route only, and assert both:

```cpp
Cost Route::SegmentAfter::penalty([[maybe_unused]] size_t profile,
                                  [[maybe_unused]] size_t vehicleType) const
{
    assert(profile == route_.profile());
    assert(vehicleType == route_.vehicleType());
    assert(start < route_.cumPenalty.size());
    return route_.cumPenalty.back() - route_.cumPenalty[start];
}
```

(same shape for `SegmentBefore`).

`SegmentBetween::penalty` (:993):

```cpp
Cost Route::SegmentBetween::penalty(size_t profile, size_t vehicleType) const
{
    // SegmentBetween is the segment type that crosses routes, and therefore
    // profiles and vehicle types, so it is the one that must be able to
    // recompute. Note the inclusive bound: penalties are node-additive.
    if (profile != route_.profile() || vehicleType != route_.vehicleType())
    {
        auto const &pen = route_.data.penalties(profile);
        Cost penalty = 0;

        for (size_t step = start; step <= end; ++step)
        {
            auto const location = route_.visits[step];
            penalty += pen[location]
                       + route_.data.lockPenalty(vehicleType, location);
        }

        return penalty;
    }

    assert(start < route_.cumPenalty.size());
    assert(end + 1 < route_.cumPenalty.size());
    return route_.cumPenalty[end + 1] - route_.cumPenalty[start];
}
```

`Segments.h:44`:

```cpp
    Cost penalty(size_t profile, size_t vehicleType) const
    {
        return data.penalty(profile, client)
               + data.lockPenalty(vehicleType, client);
    }
```

Update any other segment type in `Segments.h` (e.g. a reload-depot segment) to the two-argument signature; depots return `data.penalty(profile, depot)` unchanged (locks are never on depots).

`Proposal::penalty` (:1442):

```cpp
    auto const profile = route()->profile();
    auto const vehicleType = route()->vehicleType();

    // Penalties and locks are node-additive, so unlike distance there is no
    // cross-edge term between consecutive segments and this is a plain fold.
    auto const fn = [&](auto &&...segments)
    { return (segments.penalty(profile, vehicleType) + ...); };
```

Then `grep -rn 'penalty(' c_src/ex_vrp/search` and update every remaining caller of a segment's `penalty(profile)` to pass the target route's vehicle type (the compiler will list them).

- [ ] **Step 4: Rebuild and run, normal and with assertions**

Run: `EX_VRP_FORCE_BUILD=1 mix compile && mix test test/vehicle_lock_test.exs test/penalty_channel_test.exs test/search_route_test.exs test/local_search_test.exs`
Expected: PASS.

Run: `SANITIZE=1 EX_VRP_FORCE_BUILD=1 mix test test/vehicle_lock_test.exs test/penalty_channel_test.exs` (or `task test:asan` restricted to these files)
Expected: PASS — the `costAfter == costBefore + deltaCost` asserts hold for every move.

- [ ] **Step 5: Run the full suite and the smoke bench**

Run: `EX_VRP_FORCE_BUILD=1 mix test` then `mix bench.smoke`
Expected: all green; bench.smoke unchanged against main (no locks in its corpus).

- [ ] **Step 6: Commit**

```bash
git add c_src/ex_vrp/search test/vehicle_lock_test.exs
git commit -m "Price vehicle locks in every local-search move"
```

---

### Task 4: Trip-aware warm starts and trip read-back

**Files:**

- Modify: `lib/ex_vrp/solver.ex` (`typed_initial_routes/1` :697, the `:initial_routes` doc :78, `trimmable?/1` :489 and the rebuild at ~:584)
- Modify: `c_src/ex_vrp_nif.cpp` (the solution-from-routes constructor used for warm starts; a new `solution_trips/1`)
- Modify: `lib/ex_vrp/native.ex`
- Test: `test/multi_trip_test.exs`, `test/solve_test.exs`

**Interfaces:**

- Produces: `:initial_routes` accepts, per vehicle type, either a flat client list (unchanged meaning: one trip) or `{:trips, [%{reload_depot: depot_idx | nil, clients: [client_idx]}]}` where the first trip's `reload_depot` is `nil` (it starts at the vehicle type's start depot) and each later trip names the reload depot it starts from.
- Produces: `ExVrp.Native.solution_trips(solution) :: [[%{start_depot: non_neg_integer(), clients: [non_neg_integer()]}]]` — per route, its trips.

- [ ] **Step 1: Write the failing tests**

In `test/multi_trip_test.exs` add:

```elixir
  describe "trip-aware warm starts" do
    test "a warm start given as trips comes back with the same trips" do
      model = two_trip_model()

      {:ok, result} =
        ExVrp.Solver.solve(model,
          stop: ExVrp.StoppingCriteria.max_iterations(0),
          initial_routes: [{:trips, [%{reload_depot: nil, clients: [1, 2]}, %{reload_depot: 0, clients: [3, 4]}]}]
        )

      assert [[%{clients: [1, 2]}, %{clients: [3, 4]}]] = ExVrp.Native.solution_trips(result.best)
    end

    test "a reload depot the vehicle type cannot use is rejected and the solve starts cold" do
      model = two_trip_model()

      {:ok, result} =
        ExVrp.Solver.solve(model,
          stop: ExVrp.StoppingCriteria.max_iterations(0),
          initial_routes: [{:trips, [%{reload_depot: nil, clients: [1]}, %{reload_depot: 5, clients: [2]}]}]
        )

      assert ExVrp.Solution.num_clients(result.best) >= 0
    end
  end
```

`two_trip_model/0`: one depot, four clients of demand 1, one vehicle type with capacity 2, `reload_depots: [0]`, `max_reloads: 1` — build it with the helpers this file already uses for multi-trip models.

In `test/solve_test.exs` add a test that an infeasible multi-trip warm start (a trip over capacity) is trimmed to feasibility: seed `[{:trips, [%{reload_depot: nil, clients: [1, 2, 3]}, %{reload_depot: 0, clients: [4]}]}]` on the capacity-2 model with all clients optional, 0 iterations, and assert `ExVrp.Solution.is_feasible(result.best)`.

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/multi_trip_test.exs test/solve_test.exs`
Expected: FAIL — `{:trips, _}` is not an accepted route and `solution_trips/1` is undefined.

- [ ] **Step 3: Implement**

`typed_initial_routes/1` keeps flat lists as single-trip routes and passes `{:trips, trips}` through as a list of trips; the NIF that builds a `Solution` from warm-start routes constructs `Trip`s with the given start depot for each trip after the first (the `Trip` constructor already takes start/end depots — `c_src/ex_vrp/Trip.h:31-51`), and `Route` from those trips. Structural checks join the existing ones: a named reload depot must be in the vehicle type's `reloadDepots`, and the number of trips must not exceed `maxReloads + 1`; a violation is an invalid start (warning, cold-start fallback), never a crash.

`solution_trips/1` walks each route's `trips()` and returns `start_depot` and the client list per trip.

In `solver.ex`, the trim's rebuild (~:584) switches from `Native.solution_routes/1` to `Native.solution_trips/1` and rebuilds routes as `{:trips, ...}`; `trimmable?/1` drops the `single_trip_routes?/1` condition, and its comment is rewritten to say why trips now survive the rebuild. Update the `:initial_routes` doc (:78) with the trips form and an example.

- [ ] **Step 4: Rebuild and run**

Run: `EX_VRP_FORCE_BUILD=1 mix compile && mix test test/multi_trip_test.exs test/solve_test.exs test/reload_cost_test.exs test/relocate_with_depot_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ex_vrp c_src/ex_vrp_nif.cpp test/multi_trip_test.exs test/solve_test.exs
git commit -m "Carry trip boundaries through warm starts and the feasibility trim"
```

---

### Task 5: Drop the perturbation guard

**Files:**

- Modify: `c_src/ex_vrp/search/PerturbationManager.cpp:60-71` (`strandsTheClient`) and its callers/declaration
- Delete: `test/same_vehicle_perturbation_test.exs`
- Modify: `CHANGELOG.md` (entry written in Task 6)

**Interfaces:** none new.

- [ ] **Step 1: Record the before-numbers**

In `/home/jeroen/Documents/zelo/backend/core`, with ex_vrp as a path dependency pointing at this branch (`{:ex_vrp, path: "../../../ex_vrp", override: true}` temporarily in `mix.exs`, `EX_VRP_FORCE_BUILD=1 mix deps.compile ex_vrp --force` in test env), run the equipment test under dev mode's 100-iteration cap by removing its `dev_mode` override locally (do not commit that):

Run: `CI=true mix test test/zelo/planner/mutations/plan_equipment_test.exs`
Expected with the guard: FAIL (3 trips instead of 2) — this is the regression the guard causes.

- [ ] **Step 2: Remove the guard**

Delete `strandsTheClient` and the branch in `PerturbationManager::perturb` that skips removal when it returns true; delete the member-lookup plumbing that only the guard used. Delete `test/same_vehicle_perturbation_test.exs` — its scenario (every route one same-vehicle group) is the whole-route dock hold that vehicle locks replace.

- [ ] **Step 3: Verify**

Run: `EX_VRP_FORCE_BUILD=1 mix compile && mix test && mix bench.smoke`
Expected: all green, bench.smoke unchanged.

Re-run the zelo equipment test from Step 1 under the 100-iteration cap.
Expected: PASS (2 trips). If it still fails, the guard was not the cause: record the finding in ZELO-4306 and keep the test's `dev_mode` override.

- [ ] **Step 4: Commit**

```bash
git add -A c_src test
git commit -m "Drop the same-vehicle perturbation guard

It protected whole-route same-vehicle groups used as dock holds; vehicle locks
replace those, and on key-sized groups it cost convergence."
```

---

### Task 6: Release 0.13.0

**Files:**

- Modify: `mix.exs` (`@version "0.13.0"`), `CHANGELOG.md`, `README.md` (if it lists model setters)

- [ ] **Step 1: CHANGELOG entry**

```markdown
## 0.13.0

### Added

- **Vehicle locks.** `ExVrp.Model.set_vehicle_locks/2` locks a client to a vehicle type: any other
  vehicle type serving it pays the lock's price. Node-additive like the penalty channel, so every
  local-search move is priced with it. `ExVrp.Solution.lock_cost/1` reports the lock share of
  `penalty_cost/1`.
- **Trip-aware warm starts.** `:initial_routes` accepts `{:trips, [...]}` per vehicle type, and
  `ExVrp.Native.solution_trips/1` reads trips back. The warm-start trim now also runs on
  multi-trip routes.

### Removed

- The 0.12.2 perturbation guard for same-vehicle groups. It served whole-route groups used as dock
  holds, which vehicle locks replace, and slowed convergence of small groups.
```

- [ ] **Step 2: Full verification**

Run: `EX_VRP_FORCE_BUILD=1 mix test && mix bench.smoke && SANITIZE=1 EX_VRP_FORCE_BUILD=1 mix test test/vehicle_lock_test.exs test/penalty_channel_test.exs test/multi_trip_test.exs`
Expected: all green.

- [ ] **Step 3: Commit and hand over**

```bash
git add mix.exs CHANGELOG.md README.md
git commit -m "Release 0.13.0"
```

Push, PR, tag and hex publish are the owner's: stop here and hand over the branch name and the CHANGELOG entry.

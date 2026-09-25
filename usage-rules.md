# ExVrp usage rules

ExVrp solves vehicle routing problems through PyVRP's C++ core. You build an `ExVrp.Model`, call
`ExVrp.solve/2`, and read routes off the resulting solution.

```elixir
model =
  ExVrp.Model.new()
  |> ExVrp.Model.add_depot([])
  |> ExVrp.Model.add_vehicle_type(num_available: 2, capacity: [100], time_windows: [{0, 28_800}])
  |> ExVrp.Model.add_client(delivery: [20], service_duration: 300)
  |> ExVrp.Model.add_client(delivery: [30], service_duration: 300)
  |> ExVrp.Model.set_euclidean_matrices([{0, 0}, {10, 10}, {20, 0}])

{:ok, result} = ExVrp.solve(model, max_runtime: 30_000, seed: 42)

result.best.routes      #=> [[1, 2]]
result.best.distance    #=> 48
result.best.is_feasible #=> true
```

## Location indices are offset by the depot count

This is the single most common source of wrong answers. Clients are stored in their own list, but
every index the solver reports or accepts — route visits, client-group members, same-vehicle group
members — is a **location** index, and locations are `[depots..., clients...]`:

```elixir
location_idx = ExVrp.Model.num_depots(model) + client_idx
client_idx = location_idx - ExVrp.Model.num_depots(model)
```

With one depot, `routes: [[1, 2]]` means the first and second clients, not the second and third. Map
back through your own index before showing anything to a user. `ExVrp.Model.num_locations/1` gives
`depots + clients`, which is also the required size of every matrix.

## Add every depot before any client

`add_depot/2` shifts existing client-group and same-vehicle-group indices to keep them pointing at
the same clients. It works, but it means group indices depend on the order you called things. Build
in this order and the question never comes up:

```elixir
Model.new()
|> Model.add_depot(...)          # 1. all depots
|> Model.add_vehicle_type(...)   # 2. all vehicle types
|> Model.add_client(...)         # 3. clients, with their groups
```

## Capacity dimensions must match everywhere

Vehicle `capacity` and client `delivery`/`pickup` are lists, one entry per dimension (weight,
volume, pallets, …). Validation compares every client against the **first** vehicle type's
dimension count, and `delivery`/`pickup` default to `[0]` — a one-dimensional default that fails
validation the moment your vehicles carry two dimensions. Pass a full-width list on every client:

```elixir
|> Model.add_vehicle_type(num_available: 3, capacity: [1000, 50], time_windows: [{0, 28_800}])
|> Model.add_client(delivery: [200, 10], pickup: [0, 0])
```

## Vehicle time windows: pass `:time_windows`, never `tw_early`/`tw_late`

`VehicleType.new/1` raises `ArgumentError` on `:tw_early`, `:tw_late` or `:forbidden_windows` — they
are derived, not inputs. Give it the windows the vehicle is _available_, and it merges them and
derives the gaps as forbidden windows:

```elixir
Model.add_vehicle_type(model,
  num_available: 2,
  capacity: [100],
  time_windows: [{0, 500}, {600, 1000}]
)
# => tw_early: 0, tw_late: 1000, forbidden_windows: [{500, 600}]
```

Clients are the opposite: they take `tw_early`/`tw_late` directly (`tw_late` defaults to
`:infinity`), plus `release_time` for "not available before".

## Optional clients need `required: false` _and_ a prize

A client defaults to `required: true`, which makes it a hard constraint — if it cannot be served,
the whole solve is infeasible rather than dropping that client. To let the solver choose, mark it
optional and price it:

```elixir
Model.add_client(model, delivery: [10], required: false, prize: 5000)
```

The prize is what the solver gives up by skipping the client, so it is the knob that decides
"serve it" against "drive there". A `required: false` client with `prize: 0` will essentially always
be dropped.

## Client groups express "one of these"

A group with `required: false` becomes mutually exclusive by default (`mutually_exclusive` defaults
to `not required`), meaning at most one member is visited — the way to model alternative time slots
or alternative addresses for the same job. Members must be optional too: adding a `required: true`
client to a mutually exclusive group raises `ArgumentError`.

```elixir
{model, group} = Model.add_client_group(model, required: false)

model =
  model
  |> Model.add_client(group: group, required: false, prize: 100)
  |> Model.add_client(group: group, required: false, prize: 100)
```

Use `Model.add_same_vehicle_group/3` for the different constraint "if these are visited, one vehicle
does all of them". It takes client indices or client structs — **pass indices if you have them**.
Structs are matched by structural equality, so two clients carrying identical data are
indistinguishable: the group binds whichever equal clients come first, which may not be the ones you
meant, and the result validates cleanly while constraining the wrong stops.

```elixir
Model.add_same_vehicle_group(model, [1, 2], name: "crane_and_load")
```

## Custom matrices are per profile, and their diagonal must be zero

A model must supply at least one distance matrix; `Model.validate/1` rejects one that does not.
`Model.set_euclidean_matrices/2` derives both matrices from coordinates if that is all you have —
fine for tests, wrong for road networks. Supply one matrix per profile; a vehicle type's `profile:`
is an index into that list, which is how you give a van and a bike different travel times over the
same locations:

```elixir
model
|> Model.set_distance_matrices([van_distances, bike_distances])
|> Model.set_duration_matrices([van_durations, bike_durations])
|> Model.add_vehicle_type(num_available: 2, capacity: [100], time_windows: [{0, 28_800}], profile: 1)
```

Each matrix must be exactly `num_locations × num_locations`, ordered `[depots..., clients...]`, with
a zero diagonal. Duration matrices default to the distance matrices when omitted, which is only
correct if your distances are already expressed in time.

## The cost model lives on the vehicle type, and its terms are not on the same scale

What the solver minimises is set per vehicle type, not per solve:

| Field                | Default | Term it prices                   |
| -------------------- | ------- | -------------------------------- |
| `unit_distance_cost` | `1`     | distance travelled               |
| `unit_duration_cost` | `0`     | duration, including service time |
| `fixed_cost`         | `0`     | each vehicle the solution uses   |

Plus the prizes of any optional client left unserved. **Duration is free by default** — if you
want the solver to care about time rather than kilometres, you must set `unit_duration_cost`
yourself.

The trap is magnitude. Distance and duration are in unrelated units, and duration carries every
client's `service_duration`, so it is usually far the larger number. On a two-client instance with
`service_duration: 300`:

```elixir
# distance 48, duration 648 (48 travel + 600 service)
unit_distance_cost: 1                       # => cost 48
unit_distance_cost: 1, fixed_cost: 1000     # => cost 1048
unit_distance_cost: 1, unit_duration_cost: 2 # => cost 1344  (2 × 648 swamps the 48)
```

Price the terms against each other's actual magnitudes on your own data, or one of them silently
becomes the whole objective. `IteratedLocalSearch.Result.cost/1` reports this total, which is why
it is not a distance.

## A penalty is soft, a forbidden location is hard

Two ways to say "this vehicle should not go there", and picking the wrong one is the mistake to
avoid. Both are per routing profile, so both key off a vehicle type's `profile:`.

```elixir
model
# location 1 costs 500 extra on profile 0 — expensive, still allowed
|> Model.set_penalties([[0, 500, 0]])
# vehicles on profile 1 may never visit location 1 — pruned, not priced
|> Model.set_forbidden([[], [1]])
```

**`set_penalties/2` is soft.** It adds a cost, charged once for each visited location, and a large
enough prize outbids it. One list per profile, one cost per location in matrix order —
`[depots..., clients...]`. Because it is charged per visit rather than per leg, it does not change
under reordering within a route. Penalties must be non-negative, and depot entries must be zero —
use a depot's `reload_cost` to price a reload.

**`set_forbidden/2` is hard.** Local search prunes a forbidden location rather than costing it, so
no prize reaches it. One list of location indices per profile. It works whatever the profile count,
including single-profile models. Indices must name clients — a vehicle starts and ends at its depot
regardless, so forbidding a depot is rejected rather than quietly doing nothing.

`Model.validate/1` checks both — list count against profile count, row length against location
count, index range, sign, depot entries — so a malformed shape comes back as `{:error, messages}`
from `solve/2` rather than as an exception out of the NIF. Nothing is dropped silently: an index
that cannot be honoured is an error at both layers, because the alternative is a caller who asked
for a restriction, got none, and was never told.

`Solution.num_forbidden_visits/1` reports visits a route's own profile forbids. It is zero on
anything the solver produces, and a nonzero value is a bug.

Zone restrictions a vehicle may breach at a cost want penalties; restrictions it physically cannot
breach want forbidding. Callers who want both — expensive _and_ barred to some fleet — should set
both.

`Solution.penalty_cost/1` reports the penalty total, vehicle-lock prices included (next section).
Penalties are a real objective term rather than an infeasibility penalty, so they survive on a
feasible solution and `cost/1` minus `penalty_cost/1` is the solution's cost with penalties
excluded.

## Vehicle locks keep a client on its vehicle type

To keep a client on a particular vehicle, such as an order already loaded at that vehicle's dock,
lock it:

```elixir
Model.set_vehicle_locks(model, [%{location: 3, vehicle_type: 0, price: 5_000}])
```

A locked client pays `price` whenever any other vehicle type serves it, and nothing when its own
vehicle type does or when nobody serves it. Locks are soft, like penalties: they are priced into
every local-search move, so a price above any routing gain keeps the client in place and a lower
one lets the solver move it when that saves more. They key on **vehicle type**, not vehicle, so
locking to one vehicle means giving that vehicle its own vehicle type with `num_available: 1`.

`location` is in matrix order, as for `set_penalties/2`. At most one lock per client; depots cannot
be locked. `Solution.lock_cost/1` reports the lock share of `penalty_cost/1`.

Do not hold a client on a vehicle with a same-vehicle group spanning the whole route. Since 0.13.0
the search around such a plan rarely places new optional clients; locks replace that trick.

**Do not encode unreachability as a huge distance.** Five sites in the search layer used to read a
distance-matrix cell back and compare it against a hardcoded `1_000_000_000` to decide reachability,
which made your choice of "unreachable" number part of the solver's interface. They call the
predicate now. A model that still puts a huge number in the matrix stays roughly correct — a huge
distance still costs a lot — but it loses pruning, so the search wastes time proposing moves it
used to skip, and nothing reports it.

## Overtime needs two fields, and `shift_duration` alone is a hard cap

Three vehicle-type fields interact here, and only two of them are on the same axis:

| Field            | Axis     | Meaning                                                             |
| ---------------- | -------- | ------------------------------------------------------------------- |
| `shift_duration` | duration | nominal shift, and the baseline duration-based overtime counts from |
| `max_duration`   | duration | hard cap on route duration; defaults to `shift_duration`            |
| `overtime_start` | clock    | contracted end of shift, same axis as `:time_windows`               |

Both duration fields measure elapsed time rather than time worked — see the next section, which is
the single most common way these get misused.

`max_duration` defaulting to `shift_duration` is the part that catches people out. It means
**`unit_overtime_cost` on its own does nothing**:

```elixir
# Inert. The route is hard-capped at 480, so duration never exceeds shift_duration
# and duration-based overtime is always 0.
Model.add_vehicle_type(model, shift_duration: 480, unit_overtime_cost: 10)

# Works. Up to 60 units past the nominal shift, priced at 10 each.
Model.add_vehicle_type(model, shift_duration: 480, max_duration: 540, unit_overtime_cost: 10)
```

Overtime is then `max(0, duration - shift_duration)` — it measures how _long_ the vehicle worked,
so a route that starts late but runs only seven hours incurs none.

If your drivers are contracted until a wall-clock time rather than for a number of hours, that is a
different rule and needs `overtime_start`:

```elixir
Model.add_vehicle_type(model,
  time_windows: [{0, 86_400}],
  shift_duration: 28_800,
  max_duration: :infinity,
  overtime_start: 57_600,   # 16:00
  unit_overtime_cost: 10
)
```

Overtime becomes `max(0, route_end - overtime_start)`. A driver who runs 09:00–17:00 has worked an
hour of overtime even though the route lasted exactly the nominal eight. Setting `overtime_start`
switches the rule over completely — `shift_duration` stops feeding the overtime calculation and
does nothing but seed the `max_duration` default.

Read the result with `ExVrp.Solution.overtime/1` or `ExVrp.Route.overtime/1`.

## Duration caps measure elapsed time, not time worked

`shift_duration`, `max_duration` and `ExVrp.Route.duration/1` all measure **elapsed** time: route
start to route end, with idle time included. None of them caps how long the driver actually worked.

That distinction is invisible until a client's time window forces a wait, and then it inverts the
answer. A driver doing 300 units of driving across a day with a 600-unit gap in the middle:

```elixir
# elapsed 900, wait 600, actually worked 300
max_duration: 500   # => INFEASIBLE, despite only 300 units worked
max_duration: 1500  # => feasible
```

So a working day made of two short shifts separated by a long gap breaches an elapsed cap that the
driver's real hours would clear — and conversely, an elapsed cap generous enough to allow that day
also permits a route that genuinely works the full span.

**There is no "no more than N hours worked per day" constraint.** If that is what you need, the
solver cannot enforce it; measure it after the fact and reject or re-plan yourself:

```elixir
worked = ExVrp.Route.duration(route) - ExVrp.Route.wait_duration(route)
# equivalently: ExVrp.Route.travel_duration(route) + ExVrp.Route.service_duration(route)
```

## Warm-starting with `:initial_routes`

If you already have a plan — last night's routes, or an existing schedule you are inserting new
orders into — seed the solver instead of cold-starting:

```elixir
ExVrp.solve(model, initial_routes: [[1, 2, 3], [], [4, 5]])
```

Position in the outer list is the **vehicle type** index, so there is at most one route per
vehicle type; empty inner lists mean that vehicle type is unused. The inner lists are **location**
indices. An invalid warm start is not an error: the solver logs a warning and falls back to an
empty start, so check your logs rather than assuming it took.

A vehicle type that reloads is seeded trip by trip. The first trip leaves from the start depot, so
its `reload_depot` is `nil`; each later trip names the reload depot it leaves from:

```elixir
ExVrp.solve(model,
  initial_routes: [{:trips, [%{reload_depot: nil, clients: [1, 2]}, %{reload_depot: 0, clients: [3, 4]}]}]
)
```

To resume from a solution, use `Solution.warm_start/1`, **not** `result.best.routes`. `routes` is
in route order rather than vehicle type order, and it lists a route's clients without its reloads,
so seeding with it can put routes on the wrong vehicle types and merges every trip into one load:

```elixir
{:ok, initial_routes} = ExVrp.Solution.warm_start(result.best)
ExVrp.solve(updated_model, initial_routes: initial_routes)
```

It returns `{:error, {:vehicle_type_has_several_routes, vehicle_type}}` for a solution that runs
more than one route on a vehicle type, since `:initial_routes` cannot hold that.

## Multi-trip routes need `reload_depots`

A vehicle returns to a depot mid-route and reloads only if you say where:

```elixir
Model.add_vehicle_type(model,
  num_available: 2,
  capacity: [100],
  time_windows: [{0, 28_800}],
  reload_depots: [0],
  max_reloads: 2
)
```

`reload_depots` defaults to `[]`, which disables reloading entirely — a vehicle is then capped at
one load for the whole shift, and an instance whose total demand exceeds one load comes back
infeasible rather than reloading.

Count the reload stops with `ExVrp.Route.num_trips/1`. Do **not** read `route.trips`: the field is
declared on the struct but `ExVrp.Solution.routes/1` never fills it, so it is always `[]` even on a
route that made three trips.

## Know which scope each cap applies to

Once a route has reloads it has more than one **trip**, and the vehicle type's caps stop meaning
the same thing as each other. Each bounds either the whole route or a single trip, and confusing
the two is the easiest mistake to make here. `ExVrp.VehicleType` documents which is which, option
by option; what follows is what that choice costs you.

The two distance caps model different vehicles, and compose freely:

```elixir
# A diesel van that never refuels on the road: 250km covers its entire day,
# reloads included.
Model.add_vehicle_type(model, num_available: 1, capacity: [100], max_distance: 250_000)

# An electric van that charges whenever it is back at the depot: 250km per
# trip, and as many trips as the day allows.
Model.add_vehicle_type(model,
  num_available: 1,
  capacity: [100],
  reload_depots: [0],
  max_distance_per_trip: 250_000
)
```

Under `max_distance_per_trip: 250_000` a vehicle may drive 140km, reload, and drive another 120km —
260km across the day, and feasible, because neither trip exceeded its own 250km. The same numbers
under `max_distance: 250_000` are infeasible.

Note what picking the wrong one costs. Excess distance is penalised, and a solution that cannot
shed the penalty is discarded whole — so an over-tight cap does not shorten routes, it drops the
vehicle from the plan entirely.

Without `reload_depots` a route is exactly one trip, and the two distance caps coincide.

## Validate before you blame the solver

`ExVrp.solve/2` validates first and returns `{:error, reasons}` — a list of human-readable strings —
rather than solving something malformed. When a model misbehaves, call it directly:

```elixir
case ExVrp.Model.validate(model) do
  :ok -> :ready
  {:error, reasons} -> IO.inspect(reasons)
end
```

It catches mismatched capacity dimensions, `tw_late < tw_early`, release times past the window, bad
depot/reload indices, wrong matrix sizes, non-zero diagonals, and required clients in exclusive
groups.

## Reading the result

`solve/2` returns `{:ok, result}`; the solution is `result.best`:

- `result.best.routes` — list of visit lists, in **location** indices (see above)
- `result.best.distance`, `.duration`, `.num_clients`
- `result.best.is_feasible` — false means constraints are violated; do not ship the plan
- `result.best.is_complete` — false means required clients were left unserved
- `ExVrp.Solution.routes/1` — richer `ExVrp.Route` structs carrying `visits`, `vehicle_type`,
  `start_depot` and `end_depot`, plus NIF-backed queries like `Route.distance/1`,
  `Route.feasible?/1` and `Route.num_trips/1`. Only those four struct fields are populated;
  everything else comes from the query functions.

Check `is_feasible` before reading distances. An infeasible solution still reports numbers.

## Stopping and reproducibility

Defaults: `max_iterations: 10_000`, unlimited runtime, `num_starts: :auto`
(`div(System.schedulers_online(), 2)` independent parallel starts, best one wins).

- Bound wall-clock work with `max_runtime:` (milliseconds), not iterations — iteration cost scales
  with instance size, so a fixed iteration budget means wildly different runtimes across instances.
- **The two runtime knobs use different units.** The `:max_runtime` option is milliseconds;
  `StoppingCriteria.max_runtime/1` is seconds, as a float, matching PyVRP's `MaxRuntime`. Passing
  `30_000` to the criterion asks for eight hours.
- `seed:` makes a solve reproducible, multi-start included — starts are seeded deterministically
  from it. Add `num_starts: 1` when you also need results to match across machines: `:auto` derives
  the start count from `System.schedulers_online()`, so a 8-core box and a 32-core box explore
  differently.
- `ExVrp.StoppingCriteria` composes conditions: `StoppingCriteria.any([max_runtime(60.0),
max_iterations(5000)])`, or `no_improvement(1000)`.
- `on_progress:` takes a callback receiving progress maps, for logging long solves.
- `log_label:` namespaces this solve's log lines. Start indices only distinguish chains _within_ one
  `solve/2`, so a host running several solves at once sees the same `[exvrp start 0..3]` labels from
  all of them; `log_label: "relaxed_15"` makes them tellable apart.

Note that `IteratedLocalSearch.Result.cost/1` returns the full objective — see the cost model above
— and `:infinity` when infeasible. Do not read it as a distance.

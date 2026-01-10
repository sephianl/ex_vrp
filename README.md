# ExVrp

Elixir bindings for [PyVRP](https://github.com/PyVRP/PyVRP), a state-of-the-art
Vehicle Routing Problem (VRP) solver.

This is a **direct port of PyVRP's Python API** to Elixir, using the same C++ core
via NIFs. The API is designed to be a drop-in replacement where possible.

## Features

- Native Elixir API matching PyVRP's Python interface
- High-performance C++ solver via NIFs (using Fine library)
- Iterated Local Search with Late Acceptance Hill-Climbing
- Dynamic penalty adjustment via PenaltyManager
- Support for multiple VRP variants:
  - Capacitated VRP (CVRP)
  - VRP with Time Windows (VRPTW)
  - VRP with Pickups and Deliveries
  - Multi-depot VRP
  - Heterogeneous fleet VRP

## Installation

Add `ex_vrp` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_vrp, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
alias ExVrp.{Model, Solver, StoppingCriteria}
alias ExVrp.IteratedLocalSearch.Result

# Define a vehicle routing problem
model =
  Model.new()
  |> Model.add_depot(x: 0, y: 0)
  |> Model.add_vehicle_type(num_available: 2, capacity: [100])
  |> Model.add_client(x: 10, y: 10, delivery: [20])
  |> Model.add_client(x: 20, y: 0, delivery: [30])
  |> Model.add_client(x: 0, y: 20, delivery: [25])

# Solve with max iterations
{:ok, result} = Solver.solve(model, max_iterations: 1000, seed: 42)

# Or with time limit (seconds, like PyVRP)
{:ok, result} = Solver.solve(model, max_runtime: 60.0)

# Or with custom stopping criteria
stop = StoppingCriteria.multiple_criteria([
  StoppingCriteria.max_iterations(10_000),
  StoppingCriteria.max_runtime(30.0),
  StoppingCriteria.no_improvement(1000)
])
{:ok, result} = Solver.solve(model, stop: stop)

# Inspect results
IO.puts(Result.summary(result))
IO.puts("Feasible: #{Result.is_feasible(result)}")
IO.puts("Cost: #{Result.cost(result)}")
IO.puts("Routes: #{inspect(result.best.routes)}")
IO.puts("Distance: #{result.best.distance}")
```

## API Reference

### Solver

```elixir
# Main solve function - matches PyVRP's solve()
Solver.solve(model, opts)

# Options:
#   max_iterations: 10_000        - Max iterations (default)
#   max_runtime: nil              - Max runtime in seconds (like PyVRP)
#   stop: nil                     - Custom StoppingCriteria
#   seed: nil                     - Random seed for reproducibility
#   penalty_params: nil           - PenaltyManager.Params
#   ils_params: nil               - IteratedLocalSearch.Params
```

### Result

```elixir
# Result struct matches PyVRP's Result class
result.best            # Best Solution found
result.num_iterations  # Total iterations performed
result.runtime         # Runtime in milliseconds
result.stats           # Statistics map

# Methods
Result.cost(result)       # Cost (or :infinity if infeasible)
Result.is_feasible(result) # Boolean feasibility check
Result.summary(result)    # Human-readable summary string
```

### Stopping Criteria

All criteria match PyVRP's `pyvrp.stop` module:

```elixir
# Stop after N iterations
StoppingCriteria.max_iterations(1000)

# Stop after N seconds (float, like PyVRP's MaxRuntime)
StoppingCriteria.max_runtime(60.0)

# Stop after N iterations without improvement
StoppingCriteria.no_improvement(500)

# Stop when feasible solution found
StoppingCriteria.first_feasible()

# Combine criteria (OR logic) - matches PyVRP's MultipleCriteria
StoppingCriteria.multiple_criteria([
  StoppingCriteria.max_iterations(10_000),
  StoppingCriteria.max_runtime(300.0)
])
```

### Model Builder

```elixir
model = Model.new()
|> Model.add_depot(x: 0, y: 0)
|> Model.add_vehicle_type(
  num_available: 5,
  capacity: [100],           # Multi-dimensional capacity
  tw_early: 0,               # Time window start
  tw_late: 28800,            # Time window end (8 hours)
  max_duration: 28800,
  unit_distance_cost: 1,
  unit_duration_cost: 0
)
|> Model.add_client(
  x: 10, y: 20,
  delivery: [25],            # Delivery demand
  pickup: [0],               # Pickup demand
  service_duration: 300,     # Service time
  tw_early: 0,
  tw_late: 14400
)
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Elixir Application                      │
├─────────────────────────────────────────────────────────────┤
│  ExVrp.Solver              - Main solve() interface          │
│  ExVrp.IteratedLocalSearch - ILS with Late Acceptance HC     │
│  ExVrp.PenaltyManager      - Dynamic penalty adjustment      │
│  ExVrp.StoppingCriteria    - Stopping conditions             │
│  ExVrp.Model               - Problem builder                 │
│  ExVrp.Solution            - Solution representation         │
├─────────────────────────────────────────────────────────────┤
│  ExVrp.Native              - NIF bindings (via Fine)         │
├─────────────────────────────────────────────────────────────┤
│  c_src/ex_vrp_nif.cpp      - C++ NIF implementation          │
│  c_src/pyvrp/              - PyVRP C++ core                  │
└─────────────────────────────────────────────────────────────┘
```

### PyVRP API Mapping

| PyVRP (Python) | ExVrp (Elixir) |
|----------------|----------------|
| `model.solve(stop=..., seed=...)` | `Solver.solve(model, stop: ..., seed: ...)` |
| `result.cost()` | `Result.cost(result)` |
| `result.is_feasible()` | `Result.is_feasible(result)` |
| `result.best` | `result.best` |
| `MaxIterations(n)` | `StoppingCriteria.max_iterations(n)` |
| `MaxRuntime(secs)` | `StoppingCriteria.max_runtime(secs)` |
| `NoImprovement(n)` | `StoppingCriteria.no_improvement(n)` |
| `MultipleCriteria([...])` | `StoppingCriteria.multiple_criteria([...])` |
| `PenaltyManager.init_from(data)` | `PenaltyManager.init_from(data)` |

## Implementation Status

### Core Features ✅

- [x] Model builder (Client, Depot, VehicleType)
- [x] C++ NIF bindings via Fine
- [x] ProblemData creation
- [x] Solution extraction (routes, distance, duration, feasibility)
- [x] LocalSearch NIF (with all operators)
- [x] CostEvaluator NIF
- [x] IteratedLocalSearch (Late Acceptance Hill-Climbing)
- [x] PenaltyManager (dynamic penalty adjustment)
- [x] All stopping criteria (MaxIterations, MaxRuntime, NoImprovement, MultipleCriteria, FirstFeasible)

### Test Coverage

- 100 tests covering PyVRP API compatibility
- Tests ported from PyVRP's pytest suite
- Includes `test/pyvrp_api_test.exs` with explicit PyVRP behavior verification

## Development

### Prerequisites

- Elixir 1.15+
- C++20 compiler (gcc 11+ or clang 14+)
- Make
- Nix (optional, for reproducible builds)

### Setup

```bash
cd ex_vrp
mix deps.get
mix compile
mix test --include nif_required
```

### Running Tests

```bash
# Run all tests including NIF-dependent ones
mix test --include nif_required

# Run only pure Elixir tests
mix test
```

## License

MIT License - see LICENSE file.

## Acknowledgments

- [PyVRP](https://github.com/PyVRP/PyVRP) - The underlying solver
- [Fine](https://github.com/elixir-nx/fine) - Ergonomic C++ NIF bindings

# ExVrp

[![Hex.pm](https://img.shields.io/hexpm/v/ex_vrp.svg)](https://hex.pm/packages/ex_vrp)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ex_vrp)

Elixir bindings for [PyVRP](https://github.com/PyVRP/PyVRP), a state-of-the-art
Vehicle Routing Problem (VRP) solver.

Uses the same C++ core as PyVRP via NIFs for high-performance solving of
CVRP, VRPTW, multi-depot, heterogeneous fleet, prize-collecting, and multi-trip problems.

## Installation

Add `ex_vrp` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_vrp, "~> 0.4.0"}
  ]
end
```

Precompiled NIF binaries are available for Linux (x86_64) and macOS (ARM).
On other platforms, a C++20 compiler is required.

## Quick Start

```elixir
model =
  ExVrp.Model.new()
  |> ExVrp.Model.add_depot(x: 0, y: 0)
  |> ExVrp.Model.add_vehicle_type(num_available: 2, capacity: [100])
  |> ExVrp.Model.add_client(x: 10, y: 10, delivery: [20])
  |> ExVrp.Model.add_client(x: 20, y: 0, delivery: [30])
  |> ExVrp.Model.add_client(x: 0, y: 20, delivery: [25])

{:ok, result} = ExVrp.solve(model, max_iterations: 1000, seed: 42)

result.best.routes     #=> [[1, 2], [3]]
result.best.distance   #=> 8944
result.best.is_feasible #=> true
```

## Features

- Parallel multi-start solving (automatic core utilization)
- Time windows, service durations, and shift constraints
- Multi-dimensional capacity (weight, volume, etc.)
- Prize-collecting with optional clients
- Multi-trip routes with depot reloads
- Same-vehicle grouping constraints
- Custom distance/duration matrices
- Configurable stopping criteria
- Progress callbacks

See the [full documentation](https://hexdocs.pm/ex_vrp) for detailed API reference and examples.

## Development

### Prerequisites

- Elixir 1.15+
- C++20 compiler (gcc 11+ or clang 14+)
- Make

### Setup

```bash
mix deps.get
mix compile
mix test
```

## License

MIT License - see LICENSE file.

## Acknowledgments

- [PyVRP](https://github.com/PyVRP/PyVRP) - The underlying solver
- [Fine](https://github.com/elixir-nx/fine) - Ergonomic C++ NIF bindings

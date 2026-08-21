# ExVrp

[![Hex.pm](https://img.shields.io/hexpm/v/ex_vrp.svg)](https://hex.pm/packages/ex_vrp)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ex_vrp)

Elixir bindings for [PyVRP](https://github.com/PyVRP/PyVRP), a state-of-the-art
Vehicle Routing Problem (VRP) solver.

Uses the same C++ core as PyVRP via NIFs for high-performance solving of
CVRP, VRPTW, multi-depot, heterogeneous fleet, prize-collecting, and multi-trip problems.

The solver is an **iterated local search with late-acceptance hill-climbing**, matching
PyVRP from v0.13.0 onward. Note that PyVRP's own citation (Wouda, Lan & Kool 2024,
_INFORMS Journal on Computing_ 36(4)) describes an earlier hybrid genetic search
implementation; upstream [replaced it in v0.13.0](https://github.com/PyVRP/PyVRP/pull/778),
and ExVrp follows the current design.

## Installation

Add `ex_vrp` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_vrp, "~> 0.7"}
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

result.best.routes      #=> [[2, 1, 3]]
result.best.distance    #=> 68
result.best.is_feasible #=> true
```

Route entries are _location_ indices, not client indices — locations are ordered
`[depots..., clients...]`, so with one depot client `n` is location `n + 1`.

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

## Usage rules

ExVrp ships a [usage-rules.md](usage-rules.md) describing the semantics that are easy to get wrong
from the type specs alone — location index offsets, capacity dimensions, vehicle time windows,
optional clients, and the cost model. If your project uses
[usage_rules](https://hexdocs.pm/usage_rules), list `:ex_vrp` in your project config and sync:

```elixir
defp usage_rules do
  [file: "CLAUDE.md", usage_rules: [:ex_vrp]]
end
```

```bash
mix usage_rules.sync
```

## Development

### Prerequisites

- Elixir 1.18+
- C++20 compiler (gcc 11+ or clang 14+)
- Make

### Setup

```bash
mix deps.get
mix compile
mix test
```

`mix compile` downloads a precompiled NIF from a GitHub release. When changing anything under
`c_src/`, force a local build or your changes silently have no effect:

```bash
EX_VRP_FORCE_BUILD=1 mix compile
```

## License

MIT License - see LICENSE file.

## Acknowledgments

- [PyVRP](https://github.com/PyVRP/PyVRP) - The underlying solver
- [Fine](https://github.com/elixir-nx/fine) - Ergonomic C++ NIF bindings

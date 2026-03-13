# ExVRP — Elixir PyVRP Bindings

Elixir bindings for [PyVRP](https://github.com/PyVRP/PyVRP) v0.2.2 — a state-of-the-art VRP solver. Direct port of the Python API using the same C++ core via NIFs.

## Quick Context

- **What**: Library (hex package) that wraps PyVRP's C++ solver for Elixir
- **Consumer**: [Zelo](https://github.com/sephianl/zelo) planner pipeline uses this as a dependency
- **PyVRP docs**: https://pyvrp.readthedocs.io/ for algorithm concepts
- **Elixir API**: `mix usage_rules.docs ExVrp` or see `.claude/skills/exvrp-reference.md`

## Working on This Project

### Use the skill

Load `.claude/skills/exvrp-reference.md` before diving into implementation — it has the full API surface, data structures, solve pipeline, and test map.

### Workflow

- Enter plan mode for non-trivial changes (3+ steps or architectural decisions)
- Delegate test runs to `test-runner` subagent — verbose NIF output pollutes main context
- Use `exvrp-researcher` subagent for deep PyVRP C++ internals
- Self-review diffs before presenting
- **Always run tests (`mix test --include nif_required`) and benchmarks (`mix benchmark`) after any changes** — tests catch correctness regressions, benchmarks catch solution quality regressions across all instance sets

### Building & Testing

```bash
mix deps.get && mix compile                # compiles C++ NIF via elixir_make
mix test                                   # pure Elixir tests
mix test --include nif_required            # includes NIF-dependent tests
mix benchmark --instances ok_small         # solution quality benchmarks
```

Requires C++20 compiler (gcc 11+ or clang 14+). Set `SANITIZE=1` for AddressSanitizer builds.

### Key Conventions

- PyVRP API parity: match Python naming/behavior where possible, use Elixir idioms for the wrapper
- `:infinity` atoms → `INT64_MAX` in NIFs (for tw_late, shift_duration, max_distance, max_reloads)
- All solver times are integers (not floats) — seconds or distance units
- `cost()` returns `:infinity` for infeasible solutions; `penalised_cost()` always returns a number
- Fine library for NIF ergonomics — resources are reference-counted shared_ptrs
- Mneme (`auto_assert`) for new test assertions

### Code Style

- No inline comments on code — explain via function names and moduledoc
- Pattern match on function heads, not `case` in body
- Shallow nesting — extract helpers early
- No `opts` maps; use keyword lists or explicit parameters

### Adding New Features

1. Check if PyVRP C++ already supports it (look in `c_src/pyvrp/`)
2. Add NIF binding in `c_src/ex_vrp_nif.cpp` + `lib/ex_vrp/native.ex`
3. Add Elixir API in the appropriate module (Model, Solution, etc.)
4. Add validation in `Model.validate/1` if needed
5. Write tests (see test map in skill for organization)
6. Run benchmarks to verify no regression

### Cross-Repo Work (Zelo + ExVRP)

When a Zelo planner change requires ExVRP changes:

1. Implement and test in ex_vrp first
2. Bump version in `mix.exs`
3. Update Zelo's dependency to point to the new version
4. Test integration in Zelo

## Subagent Delegation

| Trigger                          | Subagent               | Why                                                       |
| -------------------------------- | ---------------------- | --------------------------------------------------------- |
| Run/debug tests                  | `test-runner`          | Verbose output isolation. **Read-only: never edit files** |
| Understand PyVRP C++ internals   | `exvrp-researcher`     | Deep research stays isolated                              |
| Clean up code after feature work | `elixir-refactor`      | Self-contained, behavior-preserving                       |
| Self-review before presenting    | `elixir-reviewer`      | Enforces style rules                                      |
| Review for performance issues    | `elixir-perf-reviewer` | Spots hot-loop anti-patterns                              |
| Explore unfamiliar areas         | `Explore` (built-in)   | Fast read-only search                                     |

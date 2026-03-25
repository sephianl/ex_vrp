# Workflow Orchestration

## 1. Plan Mode Default

- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately -- don't keep pushing
- Use plan mode for verification steps, not just building

## 2. Subagent Delegation

- Default to delegating. Keep main context for architecture, decisions, and user interaction
- One task per subagent for focused execution
- Run subagents in parallel when tasks are independent

### Delegation Matrix

| Trigger                           | Subagent             | Why                                                                                                           |
| --------------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------- |
| Run/debug tests                   | `test-runner`        | Verbose output pollutes main context. **Read-only: never edit files, only run `mix test` and report results** |
| Understand PyVRP internals        | `Explore` (built-in) | Deep research into C++ sources and algorithm details stays isolated                                           |
| Explore unfamiliar codebase areas | `Explore` (built-in) | Fast read-only search                                                                                         |

### Keep in Main Context

- Architectural decisions and trade-offs
- Multi-file feature implementation requiring user back-and-forth
- NIF interface design (Elixir <-> C++ boundary)
- Final integration after subagent work

## 3. Verification Before Done

- Never mark a task complete without proving it works
- Self-review your own diff before presenting -- fix minor issues (unused params, scattered logic, naming) before they stack up
- Delegate test running to `test-runner` subagent -- don't pollute main context with test output
- Ask yourself: "Would a staff engineer approve this?"

## 4. Demand Elegance (When It Matters)

- If a fix feels hacky or wrong, pause and reconsider the approach
- "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes -- don't over-engineer

## 5. Autonomous Bug Fixing

- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests -- then resolve them
- Zero context switching required from the user

## 6. Design for the Ideal

- Start from the perfect end-state: what would the ideal output/feature/API look like if there were no constraints?
- Design toward that vision, then figure out how to implement it -- not the other way around
- Don't let current code structure, missing data, or extra refactoring work limit the design
- "What do I want?" comes before "What's easy to add?"

# Testing

- Delegate test runs to `test-runner` subagent
- **Scope test runs to what changed**: run only the specific test file(s) affected, not the full suite
- For trivial checks like "does it compile", just run `mix compile --warnings-as-errors` directly -- no need to delegate
- Use `task test:asan` to run tests with AddressSanitizer + UBSan when debugging memory issues or after touching C++ code
- NIF-dependent tests require `--include nif_required`

# C++ / NIF

- The C++ NIF lives in `c_src/` and wraps the PyVRP solver core
- NIF bindings use the **Fine** library for ergonomic C++ <-> Elixir interop
- After changing C++ code: rebuild with `mix compile`, run `task test:asan` to catch memory issues
- After toolchain changes (compiler version, NIF flags): do a clean build with `task clean:nif` first
- C++ quality checks: `task cpp:check` (cppcheck + clang-tidy), `task cpp:format:check`

# Code Style

- Run `mix check` for the full quality suite (compiler warnings, dialyzer, credo, sobelow, styler)
- C++ follows clang-format rules -- run `task cpp:format` before committing C++ changes

# Key Reference

## PyVRP

ExVRP is a direct port of [PyVRP](https://pyvrp.org/) to Elixir via C++ NIFs.

- **PyVRP docs**: https://pyvrp.readthedocs.io/ -- the authoritative reference for algorithm concepts and solver behavior
- **C++ sources**: `c_src/pyvrp/` contains the ported PyVRP core

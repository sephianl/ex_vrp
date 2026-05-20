# Default `:debug`-level logging is excessive — ~150+ lines per `--fix` run with nothing to fix

**Severity:** low (cosmetic / UX)
**Component:** `Credence.Syntax`, `Credence.Semantic`, `Credence.Pattern` fix pipelines
**Observed in:** ex_vrp @ credence dep (current HEAD)

## Repro

Run on a credence-clean codebase:

```
mix credence --fix
```

(or analyze: `mix credence` — same `:debug` chatter, less of it)

## Actual

For every file scanned, the following is logged at `:debug`:

```
[debug] [credence_fix] syntax fix pipeline: source already parses, skipping
[debug] [credence_fix] starting semantic fix pipeline (max 3 passes, 6 rules)
[debug] [credence_fix] semantic pass 1: compilation OK, 1 warning(s)
[debug] [credence_fix] no rule matched diagnostic: "redefining module ExVrp.<...> (current version loaded from _build/dev/lib/ex_vrp/ebin/Elixir.<...>.beam)"
[debug] [credence_fix] semantic done. Applied: []
[debug] [credence_fix] starting pattern fix pipeline (76 rules)
[debug] [credence_fix] done. Applied: []
```

× 29 files in our case = ~200 lines of debug output even when **0 fixes are applied and 0 issues remain**.

Elixir's default `Logger.level` in `:dev`/`:test` is `:debug`, so this fires by default in any normal mix invocation.

## Expected

Quiet by default. Show:

- Per-file lines only when a fix is applied or a remaining issue is reported.
- A final summary (already exists in our thin wrapper: `applied N fix(es), M issue(s) remain`).

Verbose tracing should be opt-in: `--verbose` flag, or `MIX_DEBUG=1`, or `Logger.configure(level: :debug)` set by the user.

## Specific suggestions

1. Demote the per-file/per-phase trace logs from `:debug` to behind an explicit verbose toggle (e.g. `opts[:trace]`).
2. Keep `"no rule matched diagnostic: …"` quiet — it fires for every benign compiler warning (e.g. `"redefining module …"` happens whenever the fix pipeline re-evaluates a source whose module is already loaded in the BEAM, which is _always_ in practice).
3. The protocol-consolidation warning (`"the Enumerable protocol has already been consolidated, an implementation for ExVrp.Statistics has no effect."`) is also flagged as an "unmatched diagnostic" and shows up at debug — same problem.

## Why this matters

A 200-line `:debug` spew on a no-op run trains users to ignore the logs entirely, which means they'll also miss real `Applied: [<rule>]` events buried in the noise. Quieting the default makes the actual signal (applied fixes, remaining issues) much easier to spot.

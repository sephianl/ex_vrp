# `mix credence --fix` crashes after writing fixed file

**Severity:** medium (file is written, then the process exits with an error — caller sees failure even though work was done)
**Component:** `Credence.fix/2` / mix task
**Observed in:** ex_vrp @ credence dep (current HEAD)

## Repro

1. Have an Elixir source file with at least one credence-fixable issue. We hit it on `dev/benchmark.ex:70`:

   ```elixir
   if instances == :all, do: @instances |> Map.keys() |> Enum.sort(), else: instances
   ```

2. Run `mix credence --fix` (wired through to `Credence.fix/2` via a thin mix task; see ex_vrp `dev/mix/tasks/credence.ex`).

## Actual

The fix is **applied successfully** — the file is written with the new content (verified via git diff). Output shows the patch:

```
  L70 - if instances == :all, do: @instances |> Map.keys() |> Enum.sort(), else: instances
  L70 + if instances == :all, do: Enum.map(Enum.sort_by(@instances, fn {k, _} -> k end), fn {k, _} -> k end), else: instances
  dev/benchmark.ex: applied 1 fix(es)
```

Then the process dies:

```
** (EXIT from #PID<0.95.0>) killed
```

Exit code is non-zero. No stacktrace.

## Expected

Either complete cleanly with exit 0, or — if the fix should have aborted partway — leave the file untouched.

## Hypothesis

The PID death looks like a linked task / supervisor crash _after_ the write completes. Possibly:

- A `Task.async_stream` for "validate by recompiling after each fix" timing out
- A module-reload step (`Code.compile_string` on the fixed source) blowing up when the same module is already loaded (the debug logs show "redefining module …" warnings throughout the fix run — see [04-debug-logging-noise.md](04-debug-logging-noise.md))
- A linked process for capturing compiler diagnostics getting an `:EXIT` it doesn't handle

## Why this matters

A pre-commit hook that runs `--fix` would see the non-zero exit and fail the commit _even though the fix landed_. The user re-runs, sees no findings, and commits — but the intermediate failure is confusing and discourages running `--fix` in any automated context.

(We removed our `mix-credence-fix` pre-commit hook in part for this reason, plus the false-positives in [01](01-autofix-worsens-collection-pattern.md) and [02](02-rule-misfires-on-collection-not-iteration.md).)

## Suggested investigation

- Capture the EXIT signal in the fix driver and re-raise with a real stacktrace.
- If the issue is module re-compilation interfering with the loaded BEAM, scope the fix's compilation pass into a separate node or stop trying to re-compile a module that's already loaded by Mix.

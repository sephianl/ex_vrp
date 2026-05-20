# Credence findings (upstream)

Bug reports collected against the [credence](https://github.com/…) semantic linter dep while integrating it as a dedicated pre-commit + CI gate in ex_vrp (2026-05-20).

We run `mix credence --exit` automatically (pre-commit hook + CI step) but do **not** run `mix credence --fix` automatically — see the issues below for why.

## Reports

| #   | Title                                                                                                           | Severity | Affects `--fix`? | Affects `--exit`?    |
| --- | --------------------------------------------------------------------------------------------------------------- | -------- | ---------------- | -------------------- |
| 01  | [Autofix worsens `Map.keys \|> Enum.sort`](01-autofix-worsens-collection-pattern.md)                            | high     | yes              | no                   |
| 02  | [`no_map_keys_or_values_for_iteration` misfires on collection](02-rule-misfires-on-collection-not-iteration.md) | medium   | yes              | yes (false positive) |
| 03  | [`--fix` crashes after writing fixed file](03-fix-pipeline-crashes-after-writing.md)                            | medium   | yes              | no                   |
| 04  | [Default `:debug` logging is excessive](04-debug-logging-noise.md)                                              | low      | yes              | minor                |

## Status

Not filed upstream yet — these were discovered locally while wiring credence in. Worth bundling and filing once the integration shakes out a few more findings.

# `no_map_keys_or_values_for_iteration` fires on collection patterns, not just iteration

**Severity:** medium (false-positive on idiomatic Elixir)
**Component:** `Credence.Pattern.NoMapKeysOrValuesForIteration` (rule)
**Observed in:** ex_vrp @ credence dep (current HEAD)

## The rule's stated intent

From the rule message:

> `Map.keys/1` creates an intermediate list before passing to `Enum.sort`. Iterate the map directly — `Enum` functions accept maps and yield `{key, value}` pairs.

The hint ("iterate the map directly") presupposes that the user _only needs to iterate_, so building a `Map.keys` list is wasteful. That's a legitimate finding when true.

## The false-positive

The rule fires whenever `Map.keys(x)` flows into any `Enum` function, regardless of whether the consumer is iterating or collecting. Two pure-collection cases that should not trigger:

```elixir
# 1. Sorted list of map keys — the result IS a list of keys by design.
@instances |> Map.keys() |> Enum.sort()

# 2. Top-N keys
some_map |> Map.keys() |> Enum.take(10)
```

In both cases the output is a list of keys. You cannot "iterate the map directly" to produce a list of keys without going through some materialization step. The rule's premise doesn't apply.

The autofix is correspondingly wrong (see [01-autofix-worsens-collection-pattern.md](01-autofix-worsens-collection-pattern.md)) — it rewrites case 1 into `Enum.map(Enum.sort_by(map, fn {k, _} -> k end), fn {k, _} -> k end)`, which still materializes a list and is uglier.

## Suggested rule scoping

Only fire when the consumer is an iteration / aggregation that doesn't intrinsically need a list:

- **Should fire:** `Enum.each`, `Enum.any?`, `Enum.all?`, `Enum.find`, `Enum.count` (single-arg), `Enum.reduce` with non-list accumulator, `for ... do <side effect>`. In all of these, switching to `for {k, _} <- map` or `Enum.each(map, fn {k, _} -> ... end)` is a real win.
- **Should NOT fire:** `Enum.sort`, `Enum.sort_by`, `Enum.to_list`, `Enum.take`, `Enum.drop`, `Enum.reverse`, `Enum.uniq`, `Enum.chunk_*`, `Enum.map` (when result is bound/returned). All of these need a list as output; the `Map.keys` intermediate is the canonical way to produce it.
- **Ambiguous:** `Enum.map` consumed by another `Enum.*` — depends on the chain's terminus. Walk the pipe to its sink.

## Concrete check

Pseudo: walk the pipeline starting at the `Map.keys/1` call. If every successor in the pipe is iteration-only (per the list above), fire. If any successor is a collection op, skip.

## Workaround used in ex_vrp

For the `@instances |> Map.keys() |> Enum.sort()` case, we sidestepped the rule by iterating the map directly with `Enum.map(&elem(&1, 0)) |> Enum.sort()`, then hoisting the result to a compile-time attribute. The runtime cost is now zero, but the rule's complaint is unchanged in spirit — we still materialize a list of keys, just at compile time.

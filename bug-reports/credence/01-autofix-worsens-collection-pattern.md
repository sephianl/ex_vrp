# Autofix rewrites `Map.keys |> Enum.sort` into objectively worse code

**Severity:** high (autofix produces strictly worse output)
**Component:** `Credence.Pattern` / autofix pipeline
**Rule:** `no_map_keys_or_values_for_iteration`
**Observed in:** ex_vrp @ credence dep (current HEAD)

## Repro

`dev/benchmark.ex:70`:

```elixir
instance_list =
  if instances == :all, do: @instances |> Map.keys() |> Enum.sort(), else: instances
```

Run:

```
mix credence --fix
```

## Expected

Either:

- No fix applied (the input is the idiomatic Elixir way to get a sorted list of map keys), **or**
- A semantically-equivalent rewrite that is at least as efficient and at least as readable as the input.

## Actual

The autofix wrote:

```elixir
if instances == :all,
   do: Enum.map(Enum.sort_by(@instances, fn {k, _} -> k end), fn {k, _} -> k end),
 else: instances
```

This is strictly worse:

| Aspect            | Before                                       | After                                                                                      |
| ----------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Operations        | `Map.keys` (O(n)) + `Enum.sort` (O(n log n)) | `Enum.sort_by` on pairs (O(n log n) with tuple compares) + `Enum.map` (O(n))               |
| Comparator cost   | Atom compare                                 | Tuple destructure + atom compare via the `fn {k, _} -> k end` key fn — heavier per compare |
| Intermediate list | One (sorted keys)                            | One (sorted pairs) — same allocation count                                                 |
| Readability       | High — names the intent                      | Low — two anonymous fns extracting the same key                                            |

So the rewrite preserves the intermediate-list cost the rule purports to remove, **adds** per-comparison overhead, and obscures intent.

## Why this happens

The rule's intent is "if you're iterating a map's keys, iterate the map directly — `Enum` functions accept maps." That logic only applies when the consumer is an _iteration_ (`Enum.each`, `Enum.map` for side effects, `Enum.reduce` with non-list acc). Here the pipeline terminates in `Enum.sort/1`, which **must** materialize a list. There is no way to avoid producing a sorted list of keys — that's the function's whole purpose.

## Suggested fix

The autofix codemod for `no_map_keys_or_values_for_iteration` should bail out when:

- The pipeline ends in a list-collecting op (`Enum.sort`, `Enum.to_list`, `Enum.reverse`, `Enum.take`, `Enum.drop`, `Enum.uniq`, `Enum.chunk_*`, etc.), **or**
- The result is bound to a name / returned (i.e., used as a value, not consumed by a side-effecting iterator).

In those cases either suppress the rule (preferred — `Map.keys |> Enum.sort` is idiomatic) or, if you want to flag it, mark it as autofix-unsafe so `--fix` skips it.

## Workaround used in ex_vrp

Refactored the call site to a compile-time attribute, so the cost is zero at runtime and credence is happy:

```elixir
@sorted_instance_names @instances |> Enum.map(&elem(&1, 0)) |> Enum.sort()
```

(Still iterates the map directly per the rule's hint, but at compile time.)

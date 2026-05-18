# Credence Bugs

Status of known bugs in [Cinderella-Man/credence](https://github.com/Cinderella-Man/credence), verified against **0.5.0** (released 2026-05-14).

| #   | Bug                                                                   | Status                 |
| --- | --------------------------------------------------------------------- | ---------------------- |
| 1a  | `NoNestedEnumOnSameEnumerable` false-positives across sibling clauses | Not fixed              |
| 1b  | `NoRepeatedEnumTraversal` false-positives across separate functions   | Not fixed              |
| 2   | `Credence.fix` collapses formatting around the change site            | Partially fixed        |
| 3a  | `NoMapThenAggregate` emits undefined variable                         | Not fixed              |
| 3b  | `NoTrailingNewlineInDoc` malforms heredoc docs                        | **Fixed** in `5629c38` |
| 3c  | `NoLengthComparisonForEmpty` emits `match?/2` inside guards           | Not fixed              |

---

## Bug 1a — `NoNestedEnumOnSameEnumerable`: lexical scope ignored

### Symptom

Two sibling `def` clauses each call `Enum.map(xs, …)`. The rule flags the second one as "nested" inside the first.

### Repro

```elixir
defmodule TestNoNesting do
  def f1([h | _t], xs), do: Enum.map(xs, fn x -> x + h end)
  def f1([], xs),       do: Enum.map(xs, fn x -> x * 2 end)
end
```

Expected: 0 issues. Actual on 0.5.0: 1 issue — _"Nested Enum.map call on `xs` detected"_ (line 3).

### Why it's wrong

The two `xs` are different variable bindings (each function clause has its own). They're not nested — they're sibling.

### Current code (`lib/pattern/no_nested_enum_on_same_enumerable.ex:37`)

```elixir
def check(ast, _opts) do
  {_ast, {_, issues}} =
    Macro.prewalk(ast, {[], []}, fn node, {stack, issues} ->
      case extract_enum_call(node) do
        {:ok, func, var, meta} ->
          new_issues =
            if Enum.any?(stack, fn {_f, v} -> v == var end) do
              [%Issue{rule: :no_nested_enum_on_same_enumerable, ...}]
            else
              []
            end

          {node, {[{func, var} | stack], issues ++ new_issues}}
          #         ^^^^^^^^^^^^^^^^^^^^ push, never pop
        _ ->
          {node, {stack, issues}}
      end
    end)
  issues
end
```

`stack` is monotonic — it accumulates every `Enum.*` variable ever seen and never drops anything on scope exit. Once `xs` has been seen in clause 1's `Enum.map`, every later `Enum.*(xs, …)` in the file looks nested.

### Fix direction

Switch from `Macro.prewalk/3` to `Macro.traverse/4` (pre + post walkers) and maintain a **scope stack**. Push a frame on entering scope-introducing nodes; pop on exit:

- `def`, `defp` — function bodies
- `fn -> end` — lambdas
- `for ... do ... end` — comprehensions
- `case`, `with`, `cond` — each clause

Reference implementation already in-repo: `Credence.Pattern.NoEnumAtLoopAccess` (`lib/pattern/no_enum_at_loop_access.ex:26`) does the same with a depth counter:

```elixir
{_ast, {issues, _depth}} =
  Macro.traverse(ast, {[], 0}, &pre_walker/2, &post_walker/2)
```

We need the same shape but with a stack of frames instead of an integer counter.

### Negative tests to add

- Sibling `def` clauses each with one `Enum.map(xs, …)` → 0 issues
- Two unrelated `def`s with same parameter name → 0 issues
- Lambda shadows outer var: `xs = …; Enum.map([1,2], fn xs -> Enum.any?(xs, …) end)` → 0 issues
- Preserved positive: `Enum.map(xs, fn _ -> Enum.any?(xs, …) end)` → 1 issue

---

## Bug 1b — `NoRepeatedEnumTraversal`: same root cause, different shape

### Symptom

Two separate functions each traverse a parameter named `items`. Both calls get flagged as "repeated".

### Repro

```elixir
defmodule TestNoRepeated do
  def f1(items), do: Enum.any?(items, &(&1 > 0))
  def f2(items), do: Enum.all?(items, &(&1 < 100))
end
```

Expected: 0 issues. Actual on 0.5.0: 2 issues — one per call.

### Current code (`lib/pattern/no_repeated_enum_traversal.ex:57`)

```elixir
def check(ast, _opts) do
  {_ast, state} =
    Macro.prewalk(ast, %{}, fn
      {{:., _, [{:__aliases__, _, [:Enum]}, func]}, meta, [arg | _]} = node, acc
      when func in @enum_traversals ->
        case var_name(arg) do
          nil -> {node, acc}
          var ->
            acc = Map.update(acc, var, [{func, meta}], &[{func, meta} | &1])
            {node, acc}
        end
      node, acc -> {node, acc}
    end)

  state
  |> Enum.filter(fn {_var, calls} -> length(calls) > 1 end)
  |> Enum.flat_map(...)
end
```

The accumulator `state` is a flat `%{var_name => [calls]}` map. Variable names from different lexical scopes collide into the same key.

### Fix direction

Same as Bug 1a: scope-stack via `Macro.traverse/4`. When a frame pops, its `var_name` entries vanish; they don't pollute siblings.

---

## Bug 2 — `Credence.fix` collapses formatting

### Symptom (partially mitigated)

A single semantic fix touches more than the change site. Multi-line pipelines collapse to one line; nearby blank lines disappear.

### What upstream changed

The maintainer did real work here in commits past 0.4.3:

- `b61a96e` (May 15) — added `RuleHelpers.compile_and_capture/1` and a "skip pipeline if source doesn't compile" gate (avoids burning fixes on broken input).
- `3231cd3` (May 15) — added `RuleHelpers.normalize_sourceror_ast/1` to unwrap Sourceror's `{:__block__, _, [val]}` metadata-carrier nodes, and migrated specific rules: `no_manual_max`, `no_manual_min`, `no_multiple_enum_at`, `no_string_length_for_char_check`, `unnecessary_grapheme_chunking`.
- `e59b2ce` (May 15) — migrated `no_destructure_reconstruct`, `no_manual_list_last`.

### What still breaks

Rules that weren't migrated still do a whole-source round-trip via `Sourceror.to_string/1`. Example — `lib/pattern/no_map_then_aggregate.ex:62`:

```elixir
def fix(source, _opts) do
  source
  |> Sourceror.parse_string!()
  |> Macro.postwalk(fn ... end)
  |> Sourceror.to_string()       # ← reflows everything in the touched region
end
```

### Repro on 0.5.0

Input:

```elixir
items
|> Enum.map(fn item ->
  Enum.at(item.weights, dim, 0)
end)
|> Enum.sum()
```

Output:

```elixir
items |> Enum.reduce(0, fn el, acc -> acc + Enum.at(item.weights, dim, 0) end)
```

The pipeline structure is destroyed even though the rest of the file's formatting (now) survives.

### Reference: how to do this right (already in-repo)

`Credence.Pattern.NoNestedEnumOnSameEnumerable.fix/2` uses byte-range string patching:

```elixir
def fix(source, _opts) do
  ast = Sourceror.parse_string!(source)
  outer_calls = collect_outer_calls(ast, source)

  Enum.reduce(outer_calls, source, fn {start_kw, end_kw, outer_var}, acc ->
    fix_single_outer_call(acc, start_kw, end_kw, outer_var)
    # rewrites only the byte range of the changed node via Sourceror.patch_string/2
  end)
end
```

Only the specific node's byte range gets touched; everything else stays byte-identical.

### Fix direction

1. Audit every `fix/2` for `Sourceror.to_string/0` on the full AST.
2. Migrate each to locate target node + byte range via `Sourceror.get_range/1`, render only the replacement, and apply via `Sourceror.patch_string/2`.
3. Add a diff-size invariant to fixer tests:
   ```elixir
   test "fix does not reformat surrounding code" do
     before = File.read!("test/fixtures/realistic_120col.ex")
     after_ = Credence.fix(before, only: [MyRule])
     assert count_diff_lines(before, after_) < 30
   end
   ```

### Rules still to migrate (initial audit)

- `no_map_then_aggregate`
- `no_param_rebinding`
- `no_map_keys_or_values_for_iteration`
- (and any others matching `grep -l "Sourceror.to_string" lib/pattern/`)

---

## Bug 3a — `NoMapThenAggregate`: emits undefined variable

### Symptom

The fixer rewrites `Enum.map(coll, fn x -> body end) |> agg()` into an `Enum.reduce/3` but **fails to substitute the closure parameter inside the body**.

### Repro on 0.5.0

```elixir
# Input
clients
|> Enum.map(fn c -> Enum.at(c.delivery, dim, 0) end)
|> Enum.sum()

# Output
clients |> Enum.reduce(0, fn el, acc -> acc + Enum.at(c.delivery, dim, 0) end)
                                                  # ^^^ undefined
```

Compiler: `error: undefined variable "c"`.

### Why it fails

The rule renames the closure parameter from `c` to `el` in the function head but doesn't replace references to `c` inside the body. There's an `inline_call/2` clause meant to do this (`no_map_then_aggregate.ex:196`):

```elixir
defp inline_call(
       {:fn, _, [{:->, _, [[{param, _, ctx}], body]}]},
       var
     )
     when is_atom(param) and is_atom(ctx) do
  substitute(body, param, var)
end

defp substitute({name, _meta, ctx}, name, replacement) when is_atom(ctx),
  do: replacement
```

This **looks** correct on paper: it should extract `param = :c`, then walk `body` substituting `{:c, _, ctx}` nodes with `{:el, [], Elixir}`. But the input AST comes from `Sourceror.parse_string!/1`, which wraps the closure parameter and body differently from a vanilla `Code.string_to_quoted/1` AST. The pattern match `{:fn, _, [{:->, _, [[{param, _, ctx}], body]}]}` doesn't catch the Sourceror shape, so the clause never fires; control falls through to the fallback `inline_call/2`:

```elixir
defp inline_call(map_fn, var) do
  {{:., [], [map_fn]}, [], [var]}
end
```

…which keeps the body as-is and just appends a call. Result: `c` survives into the output unbound.

### Fix direction

Call `RuleHelpers.normalize_sourceror_ast/1` before the pattern match — the helper added in commit `3231cd3` specifically to unwrap Sourceror's `{:__block__, _, [val]}` wrappers:

```elixir
def fix(source, _opts) do
  source
  |> Sourceror.parse_string!()
  |> RuleHelpers.normalize_sourceror_ast()   # ← add this
  |> Macro.postwalk(fn ... end)
  |> ...
end
```

Other rules (`no_manual_max`, etc.) were already migrated to do this. `NoMapThenAggregate` was missed.

### Negative test to add

```elixir
test "preserves closure parameter references in body" do
  input = """
  clients |> Enum.map(fn c -> Enum.at(c.delivery, dim, 0) end) |> Enum.sum()
  """
  output = Credence.Pattern.NoMapThenAggregate.fix(input, [])
  assert match?({:ok, _}, Code.string_to_quoted(output))
  refute output =~ ~r/\bc\.delivery\b/        # `c` should be gone
  assert output =~ ~r/\bel\.delivery\b/       # `el` should replace it
end
```

---

## Bug 3b — `NoTrailingNewlineInDoc`: heredoc malformation ✅ FIXED

### Symptom (historical)

Heredoc-style `@doc """ ... """` strings — whose trailing `\n` is structural — got "fixed" by stripping the newline, which mangled the closing delimiter line.

### Fix landed in commit `5629c38` (May 7, in 0.4.3)

Two gates added:

**Check side** — skip if the line's source contains `"""`:

```elixir
def check(ast, opts) do
  source_lines =
    case Keyword.get(opts, :source) do
      nil -> nil
      source -> String.split(source, "\n")
    end

  Macro.prewalk(ast, [], fn
    {:@, meta, [{attr, _, [value]}]} = node, acc ... ->
      if trailing_newline_only?(value) and not already_heredoc?(source_lines, meta) do
        ...
      end
  end)
end

defp already_heredoc?(source_lines, meta) do
  line = Keyword.get(meta, :line)
  case Enum.at(source_lines, line - 1) do
    nil -> false
    source_line -> String.contains?(source_line, ~s("""))
  end
end
```

**Fix side** — skip if the string node carries Sourceror's `delimiter: """` metadata:

```elixir
defp fix_node({:@, meta, [{attr, attr_meta, [{:__block__, str_meta, [value]}]}]} = node)
     when attr in @doc_attrs and is_binary(value) do
  if Keyword.get(str_meta, :delimiter) == ~s(""") do
    node              # heredoc — leave alone
  else
    ...               # single-line doc — strip trailing \n
  end
end
```

### Verified on 0.5.0

```elixir
@doc """
Some description.
"""
```

`check/2` returns `[]`, `fix/2` returns source unchanged.

---

## Bug 3c — `NoLengthComparisonForEmpty`: invalid guard

### Symptom

A `length(x) == N` comparison inside a `when` guard gets rewritten to `match?([_, _, _, _], x)`, which fails to compile because `match?/2` cannot appear in a guard.

### Repro on 0.5.0

```elixir
# Input
def from_state(state) when is_list(state) and length(state) == 4, do: state

# Output
def from_state(state) when is_list(state) and match?([_, _, _, _], state), do: state
```

Compiler: `invalid expression in guards, case is not allowed in guards`.

(`match?/2` desugars to `case`, so the BEAM rejects it in guard position.)

### Why upstream's recent change didn't fix it

Commit `618a6df` _did_ touch this file, but only added a negative lookbehind so the regex doesn't match qualified calls like `String.length(x)`:

```diff
- ~r/length\((\w+)\)\s*(==|!=|>=|<=|>|<)\s*(\d+)/,
+ ~r/(?<!\.)length\((\w+)\)\s*(==|!=|>=|<=|>|<)\s*(\d+)/,
```

The guard-context bug is untouched.

### Fix direction

Detect whether the match occurs inside a `when` clause and either:

1. **Emit the issue but mark the location unfixable** (safest — works for all guard shapes).
2. **Rewrite the function head** instead of the guard:
   ```elixir
   def from_state([_, _, _, _] = state), do: state
   ```
   Requires merging guards into head patterns, which is non-trivial when combined with other guard expressions.

Option 1 is what the file's other unfixable shapes already do.

### Negative test to add

```elixir
test "does not rewrite length comparisons inside guards" do
  input = """
  def from_state(state) when is_list(state) and length(state) == 4, do: state
  """
  output = Credence.Pattern.NoLengthComparisonForEmpty.fix(input, [])
  assert output == input
  assert match?({:ok, _}, Code.string_to_quoted(output))
end
```

---

## Process improvements

Across all five remaining bugs, the same testing gaps show up:

### 1. Compile-the-output invariant

Every fixer should have a test that runs `Code.string_to_quoted/1` (or `Code.compile_string/1`) on its output. This would have caught 3a and 3c immediately.

### 2. Negative cases per check rule

Every check rule needs `does_not_flag/1` tests for the most common false-positive shapes:

- Sibling `def` clauses with the same param name
- Separate functions with the same param name
- Lambdas that shadow outer bindings
- `for` comprehensions next to standalone `Enum` calls

### 3. Diff-size invariant per fixer

```elixir
test "fix does not reformat surrounding code" do
  before = File.read!("test/fixtures/realistic_120col.ex")
  after_ = Credence.fix(before, only: [MyRule])
  assert count_diff_lines(before, after_) < 30
end
```

### 4. AST-shape parity

Rules that parse via `Sourceror.parse_string!/1` must call `RuleHelpers.normalize_sourceror_ast/1` before pattern-matching, or they hit the same trap that bit Bug 3a.

---

## Migration strategy

**Recommendation: open issues upstream, PR each fix, run fork in the interim.**

1. Open one issue per bug above, citing the verified repros.
2. Branch per concern in a fork (`scope-tracking-fix`, `no-map-then-aggregate-normalize`, `no-length-comparison-guard-skip`, `audit-sourceror-roundtrip`).
3. Until merged, point `mix.exs` at the fork:
   ```elixir
   {:credence, github: "<your-fork>/credence", branch: "scope-tracking-fix",
    only: [:dev, :test], runtime: false}
   ```
4. When PRs merge, switch back to hex.

A maintained fork is a real cost — only commit to it if upstream stays unresponsive for weeks.

---

## Implementation order

| Step | Scope                                                                               | Estimate |
| ---- | ----------------------------------------------------------------------------------- | -------- |
| 1    | Fork, add `test/fixtures/`, port repros from this doc as failing tests              | 1-2h     |
| 2    | Fix scope tracking in both rules (`Macro.traverse/4` + scope stack)                 | 3-4h     |
| 3    | Migrate `NoMapThenAggregate` to call `normalize_sourceror_ast/1`; verify Bug 3a fix | 1-2h     |
| 4    | Make `NoLengthComparisonForEmpty` skip guard contexts                               | 1-2h     |
| 5    | Audit remaining `fix/2` for `Sourceror.to_string/0`; migrate to `patch_string/2`    | 3-5h     |
| 6    | Open PRs upstream, point `mix.exs` at fork                                          | 1h       |

**Total: ~10-16h.**

---

## Out of scope

- `no_list_to_tuple_for_access` vs `no_enum_at_in_loop` rule-philosophy conflict
- The `_unfixable` suffix convention (confusing but works as designed)
- Linter performance (OOM on large files — orthogonal correctness concern)

---

## Reference files

- `deps/credence/lib/pattern/no_nested_enum_on_same_enumerable.ex` — Bug 1a; also reference for good `fix/2` byte-range patching
- `deps/credence/lib/pattern/no_repeated_enum_traversal.ex` — Bug 1b
- `deps/credence/lib/pattern/no_map_then_aggregate.ex` — Bug 3a + Bug 2 (round-trip)
- `deps/credence/lib/pattern/no_length_comparison_for_empty.ex` — Bug 3c
- `deps/credence/lib/pattern/no_enum_at_loop_access.ex` — reference for `Macro.traverse/4` with scope tracking
- `deps/credence/lib/rule_helpers.ex` — `normalize_sourceror_ast/1`, `compile_and_capture/1`

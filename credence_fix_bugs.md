# Credence Fix Bugs

Bugs in `fix/2` implementations and the `Credence.fix/2` pipeline in [credence](https://github.com/Cinderella-Man/credence), verified against `origin/main` at commit `e59b2ce` (2026-05-15). These produce broken output or destroy formatting around the change site.

For `check/2` false-positives, see `credence_check_bugs.md`.

**Environment for all bugs below:**

- credence `main` (`e59b2ce`, 3 commits ahead of the hex `0.5.0` release tagged at `ee80398`)
- sourceror `1.12.0`
- Elixir `1.19.5`
- Verified by switching `mix.exs` to `{:credence, github: "Cinderella-Man/credence", branch: "main"}` and running `Credence.Pattern.<Rule>.fix/2` directly via `mix run`.

> **Fix API note:** on main, every rule's `fix/2` takes a **source string** and returns a **source string** (it does the `Sourceror.parse_string!/1` and `Sourceror.to_string/1` internally). This differs from the AST-in/AST-out signature some earlier internal callers assumed.

> **Note for users on hex `0.5.0`:** main also includes three improvement commits not yet on hex — `b61a96e` (compile-input gate + `RuleHelpers.compile_and_capture/1`), `3231cd3` (`RuleHelpers.normalize_sourceror_ast/1` + 5 rule migrations), `e59b2ce` (2 more rule migrations). A 0.5.1 cut would ship these alongside any fix to the bugs below.

---

## Issue 1 — `NoMapThenAggregate.fix/2` produces code with undefined variables

### Repro

```elixir
source = """
defmodule Test do
  def calc(clients, dim) do
    clients
    |> Enum.map(fn c -> Enum.at(c.delivery, dim, 0) end)
    |> Enum.sum()
  end
end
"""

result = Credence.Pattern.NoMapThenAggregate.fix(source, [])
IO.puts(result)
Code.compile_string(result)
```

### Expected

Output compiles. The closure parameter `c` should be substituted everywhere in the body when it's renamed to `el`.

### Actual

```elixir
defmodule Test do
  def calc(clients, dim) do
    clients |> Enum.reduce(0, fn el, acc -> acc + Enum.at(c.delivery, dim, 0) end)
    #                                                  ^^^ never defined
  end
end
```

Compilation fails:

```
error: undefined variable "c"
└─ nofile:3:59: Test.calc/2
```

### Root cause

`lib/pattern/no_map_then_aggregate.ex:196-202` reaches the right clause for `fn c -> body end`:

```elixir
defp inline_call(
       {:fn, _, [{:->, _, [[{param, _, ctx}], body]}]},
       var
     )
     when is_atom(param) and is_atom(ctx) do
  substitute(body, param, var)
end
```

The clause fires (Sourceror parses `fn c -> …` as `{:fn, _, [{:->, _, [[{:c, _, nil}], body]}]}` — `nil` is an atom, so the guard passes).

The defect is in `substitute/3` at lines 211-223:

```elixir
defp substitute({name, _meta, ctx}, name, replacement) when is_atom(ctx),
  do: replacement

defp substitute({form, meta, args}, name, replacement) when is_list(args),
  do: {form, meta, Enum.map(args, &substitute(&1, name, replacement))}
# ...
defp substitute(other, _, _), do: other
```

For `c.delivery` (parsed as `{{:., meta, [{:c, meta, nil}, :delivery]}, meta, []}`), the second clause matches with `args = []`. `Enum.map([], …)` returns `[]`. The substitute call **never recurses into `form`**, where the `:c` reference lives. `c` survives untouched.

### Suggested fix

Fix `substitute/3` to walk into the form tuple of a remote call:

```elixir
defp substitute({form, meta, args}, name, replacement)
     when is_tuple(form) and is_list(args) do
  {substitute(form, name, replacement), meta,
   Enum.map(args, &substitute(&1, name, replacement))}
end

defp substitute({form, meta, args}, name, replacement) when is_list(args),
  do: {form, meta, Enum.map(args, &substitute(&1, name, replacement))}
```

(Insert before the existing 3-tuple clause so remote calls are picked up by the new one.)

Alternative: use `Macro.prewalk/2` over the body so every variable-shape node is visited — simpler and harder to miss edge cases.

### Suggested test

```elixir
test "preserves closure parameter references through remote calls in body" do
  input = """
  clients |> Enum.map(fn c -> Enum.at(c.delivery, dim, 0) end) |> Enum.sum()
  """
  output = Credence.Pattern.NoMapThenAggregate.fix(input, [])
  assert match?({:ok, _}, Code.string_to_quoted(output))
  refute output =~ ~r/\bc\.delivery\b/
  assert output =~ ~r/\bel\.delivery\b/
end
```

### Verified

Confirmed by swapping `mix.exs` to `{:credence, github: "Cinderella-Man/credence", branch: "main"}` at `e59b2ce` and running the repro — output is `clients |> Enum.reduce(0, fn el, acc -> acc + Enum.at(c.delivery, dim, 0) end)` and fails to compile with `undefined variable "c"`.

---

## Issue 2 — `NoLengthComparisonForEmpty.fix/2` emits `match?/2` inside `when` guards

### Repro

```elixir
source = """
defmodule Test do
  def from_state(state) when is_list(state) and length(state) == 4, do: state
end
"""

result = Credence.Pattern.NoLengthComparisonForEmpty.fix(source, [])
IO.puts(result)
Code.compile_string(result)
```

### Expected

Output compiles. The fixer should either skip this case (it's an unfixable shape inside a guard) or rewrite the function head.

### Actual

```elixir
defmodule Test do
  def from_state(state) when is_list(state) and match?([_, _, _, _], state), do: state
end
```

Compilation fails:

```
error: invalid expression in guards, case is not allowed in guards.
```

`match?/2` desugars to `case`, which is not a guard-safe construct.

### Root cause

The fixer rewrites `length(x) == N` → `match?([_, _, _, _], x)` unconditionally, without checking whether the comparison appears in a guard context.

A recent fix (`618a6df`) touched this file but only added a negative lookbehind so qualified calls like `String.length(x)` don't match:

```diff
- ~r/length\((\w+)\)\s*(==|!=|>=|<=|>|<)\s*(\d+)/,
+ ~r/(?<!\.)length\((\w+)\)\s*(==|!=|>=|<=|>|<)\s*(\d+)/,
```

The guard-context bug is unaddressed.

### Suggested fix

The safest option: detect whether the match occurs inside a `when` clause and skip the rewrite. Treat it as unfixable in that context. Other rules in the codebase already do this (e.g. `_unfixable`-suffixed variants).

A more ambitious option: rewrite the function head to merge the guard into the head pattern:

```elixir
# Before
def from_state(state) when is_list(state) and length(state) == 4, do: state
# After
def from_state([_, _, _, _] = state), do: state
```

This is non-trivial when other guard expressions are present — the safe option is preferred.

### Suggested test

```elixir
test "does not rewrite length comparisons inside guards" do
  input = """
  def from_state(state) when is_list(state) and length(state) == 4, do: state
  """
  output = Credence.Pattern.NoLengthComparisonForEmpty.fix(input, [])
  assert match?({:ok, _}, Code.string_to_quoted(output))
end
```

---

## Issue 3 — `Credence.fix/2` does not validate that its output compiles

### Summary

The fix pipeline has a "skip if input doesn't compile" gate (commit `b61a96e`) but no equivalent "revert / warn if output doesn't compile" gate. Bugs like Issues 1 and 2 above produce code that:

1. Parses (so subsequent rules keep running on it)
2. Does not compile
3. Is returned silently to the caller as if successful

This converts every buggy fixer from a noisy failure into a silent corruptor.

### Repro

```elixir
# Input compiles
source = """
defmodule Test do
  def calc(clients, dim) do
    clients
    |> Enum.map(fn c -> Enum.at(c.delivery, dim, 0) end)
    |> Enum.sum()
  end
end
"""

# Run the full pipeline
result = Credence.fix(source, [])
IO.inspect(result, label: "result")

# Output is returned with no warning
Code.compile_string(result.code)
# error: undefined variable "c"
```

`result.applied_rules` reports `[{NoMapThenAggregate, 1}]` — i.e., success — even though the resulting code does not compile.

### Where the gap is

In `lib/pattern.ex`, the pipeline orchestrator (`fix_with_trace/2`) checks `RuleHelpers.compiles?/1` on the **input** only:

```elixir
if RuleHelpers.compiles?(code_string) do
  run_fixable_rules(fixable, code_string, opts)
else
  Logger.debug("[credence_fix] source does not compile, skipping pattern fix pipeline")
  {code_string, []}
end
```

And `run_fixable_rules/3` only validates each intermediate step via `Code.string_to_quoted/1` (parse-ability), not `compile_and_capture/1` (compilability):

```elixir
case Code.string_to_quoted(source) do
  {:ok, ast} ->
    issues = rule.check(ast, check_opts)
    if issues != [] do
      fixed = rule.fix(source, check_opts)
      # ← no compile check on `fixed`
      {fixed, [{rule, length(issues)} | applied]}
    end
  ...
end
```

The top-level `Credence.fix/2` in `lib/credence.ex` calls `analyze/2` on the final output, but `analyze/2` only catches parse errors — never compilation errors.

### Suggested fix

After each rule's `fix/2` runs, validate the output with `RuleHelpers.compile_and_capture/1` (the helper added in `b61a96e`). If the output doesn't compile:

1. **Revert** to the pre-fix source for that rule (don't propagate broken output to the next rule).
2. **Log a warning** identifying the offending rule.
3. **Surface it in the return value** (e.g., `applied_rules: [..., {rule, :reverted}]`).

Sketch:

```elixir
fixed = rule.fix(source, check_opts)

cond do
  fixed == source ->
    {source, applied}

  not RuleHelpers.compiles?(fixed) ->
    Logger.warning("[credence_fix] #{name}: fix produced non-compiling output, reverting")
    {source, [{rule, :reverted} | applied]}

  true ->
    {fixed, [{rule, length(issues)} | applied]}
end
```

This makes buggy fixers easy to identify (they always show up as `:reverted` in the trace) and prevents one broken rule from poisoning the rest of the pipeline.

### Suggested tests

```elixir
test "reverts a rule whose output does not compile" do
  defmodule BrokenRule do
    use Credence.Pattern.Rule
    def fixable?, do: true
    def check(_, _), do: [%Credence.Issue{rule: :broken, message: "x", meta: %{line: 1}}]
    def fix(_, _), do: "this is not valid elixir at all <<<"
  end

  input = "defmodule Test, do: :ok"
  {output, applied} = Credence.Pattern.fix_with_trace(input, rules: [BrokenRule])
  assert output == input
  assert applied == [{BrokenRule, :reverted}]
end

test "pipeline output always compiles when input compiles" do
  # Property test against a corpus of realistic fixtures
  for path <- Path.wildcard("test/fixtures/*.ex") do
    input = File.read!(path)
    assert {:ok, _} = Code.string_to_quoted(input)
    %{code: output} = Credence.fix(input)
    assert {:ok, _} = Code.string_to_quoted(output),
           "output for #{path} did not parse"
    assert RuleHelpers.compiles?(output),
           "output for #{path} did not compile"
  end
end
```

---

## Issue 4 — `Credence.fix/2` reformats code outside the change site in unmigrated rules

### Summary

Commits `3231cd3` and `e59b2ce` (May 15) fixed formatting destruction for **some** rules: `no_manual_max`, `no_manual_min`, `no_multiple_enum_at`, `no_string_length_for_char_check`, `unnecessary_grapheme_chunking`, `no_destructure_reconstruct`, `no_manual_list_last`.

Other fixers still use the offending pattern:

```elixir
def fix(source, _opts) do
  source
  |> Sourceror.parse_string!()
  |> Macro.postwalk(fn ... end)
  |> Sourceror.to_string()        # ← whole-AST round-trip
end
```

### Repro

```elixir
source = """
defmodule Test do
  def compute(items, dim) do
    weighted =
      items
      |> Enum.map(fn item ->
        Enum.at(item.weights, dim, 0)
      end)
      |> Enum.sum()

    {:ok, weighted}
  end
end
"""

result = Credence.Pattern.NoMapThenAggregate.fix(source, [])
IO.puts(result)
```

### Expected

Only the matched `Enum.map(…) |> Enum.sum()` region is rewritten; surrounding formatting (assignment, blank lines, multi-line pipe) is preserved.

### Actual

```elixir
defmodule Test do
  def compute(items, dim) do
    weighted =
      items |> Enum.reduce(0, fn el, acc -> acc + Enum.at(item.weights, dim, 0) end)

    {:ok, weighted}
  end
end
```

The multi-line pipeline collapses to one line. (The `item.weights` reference being unsubstituted is a separate concern — Issue 1 in this file.)

### Root cause

`Sourceror.to_string/1` on the full AST reflows the entire affected region using its own line-length heuristics. Sourceror's default is 98 columns; many projects use 120. Even with matched width, AST round-trip cannot preserve blank lines or original pipe-step layout.

### Suggested fix

The pattern used by `Credence.Pattern.NoNestedEnumOnSameEnumerable.fix/2` is the correct one — locate target node byte ranges and patch only those ranges via `Sourceror.patch_string/2`:

```elixir
def fix(source, _opts) do
  ast = Sourceror.parse_string!(source)
  outer_calls = collect_outer_calls(ast, source)

  Enum.reduce(outer_calls, source, fn {start_kw, end_kw, outer_var}, acc ->
    fix_single_outer_call(acc, start_kw, end_kw, outer_var)
  end)
end
```

Only the byte range of the changed node is rewritten; everything else stays byte-identical.

### Rules to audit and migrate

Initial list — `grep -l "Sourceror.to_string" lib/pattern/` will find the rest:

- `no_map_then_aggregate`
- `no_param_rebinding`
- `no_map_keys_or_values_for_iteration`

### Suggested test (per rule)

```elixir
test "fix does not reformat surrounding code" do
  before = File.read!("test/fixtures/realistic_120col.ex")
  after_ = MyRule.fix(before, [])
  changed_lines = count_diff_lines(before, after_)
  assert changed_lines < 30, "fix touched #{changed_lines} lines"
end
```

A general-purpose helper:

```elixir
defp count_diff_lines(a, b) do
  a_lines = String.split(a, "\n")
  b_lines = String.split(b, "\n")

  a_lines
  |> Enum.zip(b_lines)
  |> Enum.count(fn {x, y} -> x != y end)
  |> Kernel.+(abs(length(a_lines) - length(b_lines)))
end
```

---

## Common patterns and process suggestions

The four fix bugs above cluster around two themes:

### Theme 1 — AST shape mismatch

Issue 1 happens because Sourceror's AST shape differs from `Code.string_to_quoted/1`'s. The `RuleHelpers.normalize_sourceror_ast/1` helper exists exactly for this, but it has to be opted into. New rules — and unmigrated old ones — silently regress.

**Suggestion:** make normalization the default in the `Credence.Pattern.Rule` behaviour's fix wrapper, with an opt-out for rules that genuinely want the raw Sourceror shape (e.g. byte-range fixers).

### Theme 2 — No output validation

Issue 3 is the umbrella problem. Every other fix bug becomes silent without a compile-output check. With one, every regression in a fixer becomes visible immediately.

**Suggestion:** add a single `compiles?(output)` check in `run_fixable_rules/3` after each `rule.fix/2`, plus a property test asserting that for any compiling input in `test/fixtures/`, every rule's output also compiles. Catches future regressions automatically.

### Testing template

Per fixable rule, add three tests:

1. **Behavior** — the fix produces the expected new content.
2. **Compilability** — `Code.string_to_quoted/1` (or `Code.compile_string/1`) succeeds on the output.
3. **Locality** — line diff is below a threshold (`< 30` lines or `< 25%`).

The codebase already has (1) for most rules. Adding (2) and (3) would have caught Issues 1, 2, and 4 before they shipped.

---

## Adjacent work already on main (so reviewers don't re-do it)

The following landed before the bugs above and is **not** what this report is about — listed here to anchor the suggested fixes:

- **`NoTrailingNewlineInDoc` heredoc malformation** — fixed in `5629c38` (2026-05-07, shipped in 0.4.3 and on main). Both `check/2` and `fix/2` now skip `@doc """ ... """` correctly. The fix for Issue 4 (formatting destruction) should follow the same patch-string approach this rule already uses.
- **`Credence.Pattern.fix_with_trace/2` skips on broken input** — added in `b61a96e` (2026-05-15, on main, not yet on hex). The gap for Issue 3 is that it does the same `RuleHelpers.compiles?/1` check on the input but not on each rule's output.
- **`RuleHelpers.normalize_sourceror_ast/1`** — added in `3231cd3` (2026-05-15). Already called by `no_manual_max`, `no_manual_min`, `no_multiple_enum_at`, `no_string_length_for_char_check`, `unnecessary_grapheme_chunking`, `no_destructure_reconstruct`, `no_manual_list_last`. Issue 1 is fixed by adding the same call to `no_map_then_aggregate`.
- **Byte-range patching in formatting-sensitive rules** — `3231cd3` and `e59b2ce` migrated the 7 rules above to avoid `Sourceror.to_string/1` on the full AST. Issue 4 lists the rules still on the old pattern.

# Credence Check Bugs

Bugs in `check/2` implementations in [credence](https://github.com/Cinderella-Man/credence), verified against `origin/main` at commit `e59b2ce` (2026-05-15). These rules emit false-positive issues even when the code is correct.

For `fix/2` and pipeline bugs, see `credence_fix_bugs.md`.

**Environment for all bugs below:**

- credence `main` (`e59b2ce`, 3 commits ahead of the hex `0.5.0` release tagged at `ee80398`)
- sourceror `1.12.0`
- Elixir `1.19.5`
- Verified by switching `mix.exs` to `{:credence, github: "Cinderella-Man/credence", branch: "main"}` and running `Credence.Pattern.<Rule>.check/2` directly via `mix run`.

The bug-site files (`no_nested_enum_on_same_enumerable.ex`, `no_repeated_enum_traversal.ex`) are byte-identical between hex `0.5.0` and `main` — these bugs apply equally to both.

---

## Issue 1 — `NoNestedEnumOnSameEnumerable` false-positives across sibling function clauses

### Repro

```elixir
defmodule TestNoNesting do
  def f1([h | _t], xs), do: Enum.map(xs, fn x -> x + h end)
  def f1([], xs),       do: Enum.map(xs, fn x -> x * 2 end)
end
```

```elixir
ast = Sourceror.parse_string!(File.read!("test_no_nesting.ex"))
Credence.Pattern.NoNestedEnumOnSameEnumerable.check(ast, [])
```

### Expected

`[]` — the two `Enum.map(xs, …)` calls are in sibling clauses, never nested.

### Actual

```elixir
[
  %Credence.Issue{
    rule: :no_nested_enum_on_same_enumerable,
    message: "Nested Enum.map call on `xs` detected. ...",
    meta: %{line: 3}
  }
]
```

### Root cause

`lib/pattern/no_nested_enum_on_same_enumerable.ex:37-62` uses a monotonic `Macro.prewalk/3` accumulator:

```elixir
Macro.prewalk(ast, {[], []}, fn node, {stack, issues} ->
  case extract_enum_call(node) do
    {:ok, func, var, meta} ->
      new_issues =
        if Enum.any?(stack, fn {_f, v} -> v == var end), do: [...], else: []

      {node, {[{func, var} | stack], issues ++ new_issues}}
      #        ^^^^^^^^^^^^^^^^^^^^^ push, never pop on scope exit
    _ ->
      {node, {stack, issues}}
  end
end)
```

Once `xs` is pushed onto `stack` in clause 1, every later `Enum.*(xs, …)` in the file is flagged as nested, regardless of lexical scope.

### Suggested fix

Switch to `Macro.traverse/4` with a **scope stack**. Push a frame on entry to a scope-introducing node, pop on exit:

- `def`, `defp`
- `fn -> end`
- `for ... do ... end`
- `case`, `with`, `cond` clauses

Reference implementation in the same codebase: `Credence.Pattern.NoEnumAtLoopAccess` (`lib/pattern/no_enum_at_loop_access.ex:26`) uses `Macro.traverse/4` with a depth counter — the same shape, just with a counter where we need a stack.

### Suggested tests

```elixir
test "does not flag sibling def clauses with same param name" do
  source = """
  defmodule T do
    def f([h | _], xs), do: Enum.map(xs, fn x -> x + h end)
    def f([], xs),      do: Enum.map(xs, fn x -> x * 2 end)
  end
  """
  ast = Sourceror.parse_string!(source)
  assert NoNestedEnumOnSameEnumerable.check(ast, []) == []
end

test "does not flag lambdas that shadow outer bindings" do
  source = """
  xs = [1, 2]
  Enum.map([3, 4], fn xs -> Enum.any?(xs, & &1 > 0) end)
  """
  ast = Sourceror.parse_string!(source)
  assert NoNestedEnumOnSameEnumerable.check(ast, []) == []
end

test "still flags actual nesting (regression guard)" do
  source = """
  Enum.map(xs, fn _ -> Enum.any?(xs, & &1 > 0) end)
  """
  ast = Sourceror.parse_string!(source)
  assert [%Issue{}] = NoNestedEnumOnSameEnumerable.check(ast, [])
end
```

---

## Issue 2 — `NoRepeatedEnumTraversal` false-positives across separate functions

### Repro

```elixir
defmodule TestNoRepeated do
  def f1(items), do: Enum.any?(items, &(&1 > 0))
  def f2(items), do: Enum.all?(items, &(&1 < 100))
end
```

```elixir
Credence.Pattern.NoRepeatedEnumTraversal.check(Sourceror.parse_string!(source), [])
```

### Expected

`[]` — `items` in `f1` and `items` in `f2` are different bindings.

### Actual

Two issues, one per call:

```elixir
[
  %Credence.Issue{message: "Repeated traversal of `items` using Enum.all?/1...", meta: %{line: 3}},
  %Credence.Issue{message: "Repeated traversal of `items` using Enum.any?/1...", meta: %{line: 2}}
]
```

### Root cause

Same family as Issue 1. `lib/pattern/no_repeated_enum_traversal.ex:57` accumulates Enum calls into a flat `%{var_name => [calls]}` map keyed by name — no scope awareness:

```elixir
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
|> Enum.filter(fn {_var, calls} -> length(calls) > 1 end)
```

Variables with the same name from different lexical scopes collide into the same map key.

### Suggested fix

Same as Issue 1 — `Macro.traverse/4` with a scope stack. When a frame pops, its entries vanish so they don't pollute siblings.

### Suggested tests

```elixir
test "does not flag separate functions traversing same-named params" do
  source = """
  defmodule T do
    def f1(items), do: Enum.any?(items, & &1 > 0)
    def f2(items), do: Enum.all?(items, & &1 < 100)
  end
  """
  ast = Sourceror.parse_string!(source)
  assert NoRepeatedEnumTraversal.check(ast, []) == []
end

test "still flags actual repeated traversal in same scope (regression guard)" do
  source = """
  def stats(list) do
    {Enum.max(list), Enum.min(list), Enum.count(list)}
  end
  """
  ast = Sourceror.parse_string!(source)
  issues = NoRepeatedEnumTraversal.check(ast, [])
  assert length(issues) == 3
end
```

---

## Common pattern

Both check bugs share a single root cause: **monotonic accumulators in `Macro.prewalk/3` that ignore lexical scope**.

`Credence.Pattern.NoEnumAtLoopAccess` already demonstrates the right shape using `Macro.traverse/4`. The fix for Issues 1 and 2 is the same template, repeated twice — extract a helper if doing both at once.

### Suggested helper

```elixir
defmodule Credence.ScopeWalk do
  @scope_introducing [:def, :defp, :fn, :for, :case, :with, :cond]

  @doc """
  Walks `ast` maintaining a stack of scope frames.
  Calls `fun.(node, current_frame)` on entry and pops the frame on exit.
  """
  def traverse(ast, initial_frame, fun) do
    Macro.traverse(
      ast,
      {[initial_frame], []},
      &pre(&1, &2, fun),
      &post/2
    )
  end

  defp pre({tag, _, _} = node, {stack, issues}, fun) when tag in @scope_introducing do
    new_frame = fun.(node, hd(stack), :enter)
    {node, {[new_frame | stack], issues}}
  end

  defp pre(node, {[frame | _] = stack, issues}, fun) do
    {new_frame, new_issues} = fun.(node, frame, :visit)
    {node, {[new_frame | tl(stack)], new_issues ++ issues}}
  end

  defp post({tag, _, _} = node, {[_top | rest], issues}) when tag in @scope_introducing do
    {node, {rest, issues}}
  end

  defp post(node, acc), do: {node, acc}
end
```

(Sketch — exact API depends on what each rule needs in the frame.)

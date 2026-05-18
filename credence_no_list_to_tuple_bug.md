# Credence `NoListToTupleForAccess` Fix Bug

A `fix/2` bug in [credence](https://github.com/Cinderella-Man/credence), verified against `origin/main` at commit `e59b2ce` (2026-05-15). Distinct from the issues in `credence_check_bugs.md` / `credence_fix_bugs.md` — surfaced by running the full pipeline against a real codebase rather than against minimal repros.

**Environment:**

- credence `main` (`e59b2ce`, 3 commits ahead of the hex `0.5.0` release tagged at `ee80398`)
- sourceror `1.12.0`
- Elixir `1.19.5`
- Verified by switching `mix.exs` to `{:credence, github: "Cinderella-Man/credence", branch: "main"}` and running `Credence.Pattern.NoListToTupleForAccess.fix/2` directly via `mix run`.

---

## Issue — `NoListToTupleForAccess.fix/2` introduces O(n) → O(n²) regressions and leaves dead bindings

### Repro

```elixir
source = """
defmodule Demo do
  def f(coords, indices) do
    coords_tuple = List.to_tuple(coords)

    Enum.reduce(indices, [], fn idx, acc ->
      {x, y} = elem(coords_tuple, idx)
      [{x, y} | acc]
    end)
  end
end
"""

fixed = Credence.Pattern.NoListToTupleForAccess.fix(source, [])
IO.puts(fixed)
```

### Expected

Either:

- The rule does not flag this — the `List.to_tuple/1` exists precisely to make repeated random access O(1) inside the loop. Replacing `elem(tuple, idx)` with `Enum.at(list, idx)` is a performance regression, not a fix.
- Or, if the rule does want to rewrite this, it also removes the now-dead `coords_tuple = List.to_tuple(coords)` line and only does so when the access is one-shot, not inside a loop.

### Actual

```elixir
defmodule Demo do
  def f(coords, indices) do
    coords_tuple = List.to_tuple(coords)   # ← dead binding, never read

    Enum.reduce(indices, [], fn idx, acc ->
      {x, y} = Enum.at(coords, idx)         # ← O(n) per iteration, was O(1)
      [{x, y} | acc]
    end)
  end
end
```

The output compiles (with `warning: variable "coords_tuple" is unused`), but:

1. **Semantic regression** — `elem(tuple, idx)` is O(1); `Enum.at(list, idx)` walks the list. Inside an `Enum.reduce/3` over `indices`, the loop goes from O(m) to O(m × n) where `n = length(coords)`.
2. **Dead code left behind** — the `tuple = List.to_tuple(list)` assignment exists only as a setup step for the now-removed `elem/2` calls. The fixer doesn't remove it.

### Empirical impact

Running `Credence.Pattern.NoListToTupleForAccess.fix/2` over `ex_vrp/lib/**/*.ex` (2026-05-18 against `e59b2ce`):

| File                          | Sites |
| ----------------------------- | ----- |
| `lib/ex_vrp/model.ex`         | 1     |
| `lib/ex_vrp/neighbourhood.ex` | 2     |
| `lib/ex_vrp/read.ex`          | 1     |

All four sites are intentional `t = List.to_tuple(list)` followed by `elem(t, idx)` _inside an `Enum.reduce/3` over indices_ — the canonical Elixir idiom for O(1) random access in a loop. After applying the fix, `mix compile` succeeds with two `unused variable` warnings (`coords_tuple`, `clients_tuple`); the project's hot paths now do O(list) work per iteration that was O(1) before.

Diff from `lib/ex_vrp/neighbourhood.ex:177-189` (worst-case site — `elem` was called four times inside an `Enum.reduce/3` over `rest`):

```diff
     initial_costs =
       Nx.add(
-        Nx.multiply(unit_dist, elem(distances_tuple, profile)),
-        Nx.multiply(unit_dur, elem(durations_tuple, profile))
+        Nx.multiply(unit_dist, Enum.at(distances, profile)),
+        Nx.multiply(unit_dur, Enum.at(durations, profile))
       )

     Enum.reduce(rest, initial_costs, fn {ud, ut, p}, acc ->
       costs =
         Nx.add(
-          Nx.multiply(ud, elem(distances_tuple, p)),
-          Nx.multiply(ut, elem(durations_tuple, p))
+          Nx.multiply(ud, Enum.at(distances, p)),
+          Nx.multiply(ut, Enum.at(durations, p))
         )
```

### Root cause

`lib/pattern/no_list_to_tuple_for_access.ex` looks for `elem(t, i)` where `t` was bound via `List.to_tuple/1`. It rewrites `elem(t, i)` → `Enum.at(<original list>, i)` but does not:

- Check whether the `elem` site is inside a loop scope (`Enum.reduce`, `for`, lambda, nested function) — when it is, the binding exists _for_ the loop's random access pattern and the rewrite turns O(1) into O(n).
- Remove the originating `t = List.to_tuple(list)` assignment when its only readers are the rewritten `elem/2` calls — leaves dead code.
- Check whether `t` has multiple `elem` readers — multiple rewrites compound the regression.

### Suggested fix

In priority order:

1. **Best**: demote the rule to check-only with a message explaining when this pattern is and isn't appropriate. Stop auto-fixing. The pattern `List.to_tuple/1` → `elem/2` in a loop is _idiomatic_ Elixir for "I need O(1) random access on a sequence"; rewriting it is wrong in the common case.

2. **Acceptable**: gate the auto-fix on all of:
   - The `tuple` binding has exactly one reader (the `elem/2`)
   - That reader is not inside any nested function / lambda / comprehension / `Enum.reduce` scope created after the binding
   - The originating `t = List.to_tuple(list)` line is also removed

3. **Worst-of-both**: keep the rewrite but also delete the dead binding. This still introduces a perf regression on single-use cases that the user wrote intentionally.

### Suggested tests

```elixir
test "does not auto-fix when tuple is used inside a loop" do
  input = """
  t = List.to_tuple(list)
  Enum.reduce(idxs, [], fn i, acc -> [elem(t, i) | acc] end)
  """
  assert Credence.Pattern.NoListToTupleForAccess.fix(input, []) == input
end

test "does not auto-fix when tuple is used inside a comprehension" do
  input = """
  t = List.to_tuple(list)
  for i <- idxs, do: elem(t, i)
  """
  assert Credence.Pattern.NoListToTupleForAccess.fix(input, []) == input
end

test "removes dead tuple binding when single-use fix is applied" do
  input = """
  t = List.to_tuple(list)
  elem(t, idx)
  """
  output = Credence.Pattern.NoListToTupleForAccess.fix(input, [])
  refute output =~ ~r/List\.to_tuple/
end
```

### Why this slips past existing checks

The fix output compiles (only `unused variable` warnings). So the proposed output-compile gate from `credence_fix_bugs.md` Issue 3 would not catch this — the damage is semantic (performance) and dead-code, not syntactic. Catching this category requires either:

- A `compile-output-and-check-warnings` gate (treat new `unused variable` warnings as a fail signal)
- Or simply trusting the rule's behavior at the design level — see the "demote to check-only" suggestion above.

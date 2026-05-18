# Credence Audit Follow-Up Comments

Follow-up findings from running credence `main` (`e59b2ce`) over `ex_vrp/lib/**/*.ex` on 2026-05-18. Three upstream reports exist: `credence_check_bugs.md`, `credence_fix_bugs.md`, and the standalone `credence_no_list_to_tuple_bug.md`.

Both comments below are paste-on follow-ups for the **fix-bugs report**. They cross-reference the standalone `NoListToTupleForAccess` filing because it provides a concrete example that sharpens two of the proposed fix-bug remediations. Nothing to add to the check-bugs report — the original repros and the `Macro.traverse + scope stack` fix sketch already cover every false-positive shape the audit surfaced.

---

## Comment for the Fix report — Issue 3 (`compiles?/1` post-fix gate)

> Cross-reference: the `NoListToTupleForAccess` bug filed alongside this audit (`credence_no_list_to_tuple_bug.md`) is an example of a fix that produces output that **compiles cleanly** — so the proposed `Credence.RuleHelpers.compiles?/1` gate would happily ship it.
>
> The rewrite turns `elem(tuple, idx)` into `Enum.at(list, idx)` inside an `Enum.reduce/3` over indices (O(1) → O(n) per iteration, an actual perf regression) and orphans the originating `tuple = List.to_tuple(list)` line. Both effects show up only as `unused variable "..._tuple"` warnings at compile time, not errors. Repro and details in the separate file.
>
> Practical implication for Issue 3: a `compiles?/1` gate using `Code.compile_string/1` with default options is insufficient as a safety net. Two options to close the hole:
>
> 1. Treat newly-introduced warnings as errors. Roughly: capture `Code.put_compiler_option(:warnings_as_errors, true)` (or compare the warning set before/after the fix and fail if it grew). This catches the dead-binding and any other "fix removed the only reader of a binding" class of bug for free.
> 2. Optionally also reject fixes whose output reformats lines the rule didn't touch — that overlaps with Issue 4 but would catch the dead-code class too.
>
> Without one of these, Issue 3's gate guards only against syntactic damage, not against the larger "fix output is technically valid Elixir but semantically wrong" class.

---

## Comment for the Fix report — Issue 4 (formatting destruction via round-trip)

> Audit follow-up — the mechanism is broader than the original report describes, and the natural fix unit is the `Credence.Pattern.Rule` behaviour itself, not per-rule migration.
>
> ### Mechanism correction
>
> The original report focused on `Sourceror.parse_string!/1 |> Sourceror.to_string/1`. There is a second, separate round-trip mechanism in the codebase: the 7 rules touched by commits `3231cd3` / `e59b2ce` (the `RuleHelpers.normalize_sourceror_ast/1` family) use `Code.string_to_quoted!/1` paired with `Macro.to_string/1` (or, worse, `Sourceror.to_string/1` on an AST that never had Sourceror metadata):
>
> | Rule                              | Parser                   | Stringifier           | Short-circuits no-ops? |
> | --------------------------------- | ------------------------ | --------------------- | ---------------------- |
> | `no_manual_max`                   | `Code.string_to_quoted!` | `Sourceror.to_string` | no                     |
> | `no_string_length_for_char_check` | `Code.string_to_quoted!` | `Sourceror.to_string` | no                     |
> | `no_manual_min`                   | `Code.string_to_quoted!` | `Macro.to_string`     | no                     |
> | `unnecessary_grapheme_chunking`   | `Code.string_to_quoted!` | `Macro.to_string`     | no                     |
> | `no_destructure_reconstruct`      | `Code.string_to_quoted!` | `Macro.to_string`     | no                     |
> | `no_multiple_enum_at`             | `Code.string_to_quoted!` | `Macro.to_string`     | **yes**                |
> | `no_manual_list_last`             | `Code.string_to_quoted!` | `Macro.to_string`     | **yes**                |
>
> The two mixed-parser rows are the worst case: `Code.string_to_quoted!/1` produces an AST without the position/format metadata Sourceror relies on, so `Sourceror.to_string/1` pretty-prints from scratch _and_ loses the formatting Sourceror would otherwise preserve.
>
> Across the full `lib/pattern/` (91 rules, 76 fixable), only ~14 implement any short-circuit. The other ~62 unconditionally reformat the file even when the rule had nothing to fix.
>
> ### Suggested fix unit — the behaviour, not the rules
>
> `Credence.Pattern.Rule` currently exposes `fix/2` as the callback, with rules implementing the full parse → walk → stringify pipeline themselves (`lib/pattern/rule.ex`). The migrations so far have been per-rule, which is why they've diverged in approach and most still don't short-circuit.
>
> A behaviour-level wrapper would fix all ~62 in one change. Sketch:
>
> ```elixir
> defmodule Credence.Pattern.Rule do
>   @callback transform_ast(Macro.t(), keyword()) :: Macro.t()
>   @optional_callbacks transform_ast: 2
>
>   defmacro __using__(_opts) do
>     quote do
>       @behaviour Credence.Pattern.Rule
>       alias Credence.Issue
>
>       @impl true
>       def fixable?, do: false
>
>       @impl true
>       def priority, do: 500
>
>       @impl true
>       def fix(source, opts) do
>         if function_exported?(__MODULE__, :transform_ast, 2) do
>           ast =
>             source
>             |> Sourceror.parse_string!()
>             |> Credence.RuleHelpers.normalize_sourceror_ast()
>
>           case __MODULE__.transform_ast(ast, opts) do
>             ^ast -> source
>             new_ast -> Sourceror.to_string(new_ast)
>           end
>         else
>           source
>         end
>       end
>
>       defoverridable fixable?: 0, priority: 0, fix: 2
>     end
>   end
> end
> ```
>
> Per-rule work then collapses to a `transform_ast/2` that returns the (possibly walked) AST. The behaviour handles parsing once, normalization once, the `original_ast == new_ast -> source` short-circuit, and stringification — eliminating both the divergence between rules and the unconditional reformat.
>
> The two existing structural exceptions (`Sourceror.patch_string/2` in `no_list_to_tuple_for_access`, the manual byte-range patching in `no_nested_enum_on_same_enumerable`) can keep overriding `fix/2` directly via `defoverridable`.

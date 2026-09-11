# Elixir Style Rules

These rules are non-negotiable. Every violation must be fixed (refactor) or flagged (review).
They are shared with [Zelo](https://github.com/sephianl/zelo); rules 8, 11 and 12 are
Ash/Appsignal-specific and have no bite in this repo, but are kept here so the list stays one
list.

1. **One place per rule.** Every piece of logic lives in exactly one place. Before writing a
   function, query or component, find the existing one and extend it. When two callers need the
   same rule at different scopes, share the rule and parameterise the difference — never copy it
   and adjust. Duplicating is a last resort, and must be called out in the response with the
   reason. Never silently.

2. **Code explains itself.** If a reader needs help following it, the answer is more functions
   and modules with descriptive names, and pattern matching on heads — not prose. A name is the
   primary documentation; reach for a doc paragraph only when the name genuinely cannot carry
   the meaning.

3. **No inline comments.** No comments next to or above lines of code. Test docstrings are fine.

4. **Moduledocs add something.** State what the module is, plus the one or two things a reader
   genuinely cannot get from the code. Not a record of decisions, alternatives weighed, or
   incidents fixed — that belongs in the PR. A moduledoc explaining how the code works means the
   code needs the work instead.

5. **No `opts` keyword lists as parameters.** Use explicit, well-named function parameters.
   `def create_order(customer, address, priority)` not `def create_order(opts)`.

6. **Pattern match on function heads.** Use multiple function clauses for different cases. Do
   not use `if`/`else`/`case` in function bodies when pattern matching on heads would work. Do
   not use `Map.get` for known keys — destructure or pattern match instead.

7. **Prefer small modules.** 400 lines is a guideline, not a hard rule. Prefer splitting large
   modules into focused sub-modules under a directory matching the parent module name, but don't
   over-engineer extractions just to hit a number.

8. **No `%RuntimeError{}` for Appsignal errors.** Always use a dedicated `defexception` module
   so errors are trackable separately in Appsignal. See `RoutingEngineError` or
   `DebugUploadError` for the pattern.

9. **No `Map.get` for known keys.** When the map shape is known, pattern match in function heads
   or destructure. `Map.get` with a default is a code smell when you already know what keys
   exist.

10. **No trivial wrapper functions.** Don't write one-line private functions that just delegate
    to another module's function. Call the target directly at the call site. Only wrap if the
    wrapper adds real value (default args, error handling, argument transformation).

11. **No bang (`!`) functions in non-test code.** Use the non-bang variant (`Ash.load`,
    `Repo.insert`, etc.) with proper `{:ok, _}` / `{:error, _}` handling. Bang functions are only
    acceptable in test code.

12. **Use code interface actions, not raw Ash calls.** Always use the resource's code interface
    (`Resource.action_name`) instead of generic `Ash.get!`, `Ash.create!`,
    `Ash.Changeset.for_create` etc. The code interface exists to be used — raw Ash calls bypass
    validations and obscure intent.

13. **Names stand alone at the point of use.** A module or function name must be meaningful
    where it is _referenced_, not only where it is defined. `Result`, `Input`, `Data`, `Helper`,
    `Utils`, `Handler` and `Manager` borrow all their meaning from the directory they sit in and
    lose it the moment they are aliased — `alias Foo.Bar.Result` leaves the call site saying
    nothing. Name the thing, not its role. This applies to files and directories too: the path
    is context, never the name.

## Notes for this repo

C++ under `c_src/` is vendored from PyVRP and follows upstream's conventions — rule 3 does not
apply there, and comments explaining non-obvious algorithm decisions are expected.

`credo --strict` and `mix reach.check` must report zero findings; see `.check.exs`. The linters
catch none of rules 1, 2, 4, 10 or 13 — those are naming and single-sourcing rules and need a
reader.

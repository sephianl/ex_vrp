defmodule CredoChecks.AppendInLoop do
  @moduledoc """
  Flags `list ++ anything` inside loops where repeated concatenation is O(n²).

  The `++` operator copies the entire left-hand list. Inside a loop this
  compounds: n iterations × O(n) copy = O(n²).

  Prepending (`[item | acc]`) is O(1). A single `Enum.reverse/1` at the end
  is O(n), making the total O(n).

  `[item] ++ list` (prepend) is fine and not flagged.

  Only triggers inside: `Enum.reduce`, `Enum.reduce_while`, `Enum.map_reduce`,
  `Enum.scan`, `Enum.flat_map_reduce`, `List.foldl`, `List.foldr`,
  `for/reduce` comprehensions, and recursive functions.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      The `++` operator copies the entire left-hand list. A one-off
      concatenation is O(n) — same as `Enum.reverse/1` — and perfectly fine.

      Inside a loop, however, the cost compounds:
      n iterations × O(n) copy = **O(n²)**.

      Use `[item | acc]` to prepend (O(1) per iteration) and call
      `Enum.reverse/1` once at the end when order matters.

      This check only flags `++` inside loops (reduce, fold, for/reduce,
      recursive functions). One-off concatenations are not flagged.
      """
    ]

  @reduce_funs [:reduce, :reduce_while, :map_reduce, :scan, :flat_map_reduce]
  @list_folds [:foldl, :foldr]

  @impl Credo.Check
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    case Credo.Code.ast(source_file) do
      {:ok, ast} ->
        recursive_funs = find_recursive_functions(ast)

        {_ast, state} =
          Macro.traverse(
            ast,
            %{loop_depth: 0, issues: [], recursive_funs: recursive_funs},
            &pre(&1, &2, issue_meta),
            &post/2
          )

        state.issues

      {:error, _} ->
        []
    end
  end

  defp pre(node, state, issue_meta) do
    state =
      if loop_node?(node, state),
        do: %{state | loop_depth: state.loop_depth + 1},
        else: state

    state = check_concat(node, state, issue_meta)

    {node, state}
  end

  defp post(node, state) do
    state =
      if loop_node?(node, state),
        do: %{state | loop_depth: state.loop_depth - 1},
        else: state

    {node, state}
  end

  # [item] ++ list is prepend — always fine, skip.
  # But NOT [a | b] ++ list — that's [a, ...b] ++ list which copies the left side.
  defp check_concat({:++, _meta, [[item], _]}, state, _issue_meta)
       when not (is_tuple(item) and tuple_size(item) == 3 and elem(item, 0) == :|), do: state

  # list ++ anything inside a loop — O(n²)
  defp check_concat({:++, meta, [_, _]}, %{loop_depth: depth} = state, issue_meta) when depth > 0 do
    issue =
      format_issue(
        issue_meta,
        message:
          "`++` inside a loop copies the left-hand list every iteration (O(n²)). " <>
            "Prepend with `[item | acc]` and `Enum.reverse/1` when order matters.",
        trigger: "++",
        line_no: meta[:line]
      )

    %{state | issues: [issue | state.issues]}
  end

  defp check_concat(_node, state, _issue_meta), do: state

  # --- Loop detection ---

  # Enum.reduce/2-3, Enum.reduce_while/3, Enum.map_reduce/3, etc.
  defp loop_node?({{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, args}, _state)
       when fun in @reduce_funs and is_list(args), do: true

  # List.foldl/3, List.foldr/3
  defp loop_node?({{:., _, [{:__aliases__, _, [:List]}, fun]}, _, args}, _state)
       when fun in @list_folds and is_list(args), do: true

  # for ... reduce: ... do ... end
  defp loop_node?({:for, _, args}, _state) when is_list(args) do
    Enum.any?(args, fn
      kw when is_list(kw) -> Keyword.has_key?(kw, :reduce)
      _ -> false
    end)
  end

  # Recursive def/defp — guarded clause first (non-guarded also matches {:when, _, _} as {name, _, _})
  defp loop_node?({kind, _, [{:when, _, [{name, _, _} | _]} | _]}, %{recursive_funs: rf})
       when kind in [:def, :defp] and is_atom(name), do: MapSet.member?(rf, name)

  defp loop_node?({kind, _, [{name, _, _} | _]}, %{recursive_funs: rf}) when kind in [:def, :defp] and is_atom(name),
    do: MapSet.member?(rf, name)

  defp loop_node?(_node, _state), do: false

  # --- Recursive function detection ---

  # Pre-pass: collect names of functions whose body calls themselves.
  defp find_recursive_functions(ast) do
    {_ast, funs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {kind, _, [head, body_kw]} = node, acc when kind in [:def, :defp] ->
          name = fun_name(head)
          body = body_from(body_kw)

          if name && body && calls?(body, name) do
            {node, MapSet.put(acc, name)}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    funs
  end

  defp fun_name({:when, _, [{name, _, _} | _]}) when is_atom(name), do: name
  defp fun_name({name, _, _}) when is_atom(name), do: name
  defp fun_name(_), do: nil

  defp body_from(kw) when is_list(kw), do: Keyword.get(kw, :do)
  defp body_from(_), do: nil

  defp calls?(ast, name) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {^name, _, args} = node, _acc when is_list(args) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end
end

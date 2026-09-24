defmodule VerifyCitations do
  @moduledoc """
  Fails when a skill cites code that no longer exists.

  Skills are prose about code, so nothing compiles them and nothing catches a
  rename. This resolves every backticked token in `.claude/skills/**/*.md`
  against the repo: file paths and globs, Elixir modules and `Mod.fun/arity`
  (against the compiled app, `ExVrp.` prefix optional), bare `fun/arity`
  (any `def`/`defp` in the repo), C++ names (`Class::member`, camelCase,
  `Template<...>`, grepped in `c_src/`), commit hashes and mix tasks.
  Line-number citations are counted separately: they rot on any edit above
  them and should be symbols instead.

  Tokens with spaces are prose, not citations, and are skipped — as are atoms,
  bare snake_case option names, literals and upstream-only paths (`.py`).
  Names a skill cites precisely because they are gone go in `@absent_by_design`.

      mix run .claude/skills/verify_citations.exs
  """

  @root Path.expand("../..", __DIR__)
  @elixir_dirs ~w(lib test dev)
  @cpp_dirs ~w(c_src)
  @repo_top_dirs ~w(lib test dev c_src priv .claude)
  @absent_by_design ~w(SubPopulation)

  def run do
    __DIR__
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.flat_map(&check_file/1)
    |> report()
  end

  defp check_file(path) do
    rel = Path.relative_to(path, @root)

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} -> check_line(line, n, rel) end)
  end

  defp check_line(line, n, rel) do
    ~r/`([^`\s]+)`/
    |> Regex.scan(line)
    |> Enum.flat_map(fn [_, token] -> token |> classify() |> as_findings(rel, n, token) end)
  end

  defp as_findings(:ok, _rel, _n, _token), do: []
  defp as_findings(kind, rel, n, token), do: [{kind, rel, n, token}]

  defp classify(token) do
    cond do
      skipped?(token) -> :ok
      token in @absent_by_design -> :ok
      Regex.match?(~r/^[\w\/.-]+\.(ex|exs|cpp|h):\d+$/, token) -> :line_cite
      path_like?(token) -> resolve_path(token)
      Regex.match?(~r/^[\w.-]+\.(ex|exs|cpp|h)$/, token) -> token |> basename_known?() |> verdict(:missing_file)
      Regex.match?(~r/^[0-9a-f]{7,40}$/, token) -> resolve_commit(token)
      String.contains?(token, "::") -> resolve_cpp(token)
      Regex.match?(~r/^[A-Z][\w.]*\.[a-z_]\w*[?!]?(\/\d+)?$/, token) -> resolve_elixir_function(token)
      Regex.match?(~r/^[a-z_]\w*[?!]?\/\d+$/, token) -> resolve_bare_function(token)
      Regex.match?(~r/^[A-Z][\w.]*$/, token) -> resolve_module_or_cpp(token)
      Regex.match?(~r/^[a-z]\w*[A-Z]\w*_?$/, token) -> resolve_cpp(token)
      Regex.match?(~r/^[a-z_]+\.[a-z_.]+$/, token) -> resolve_mix_task(token)
      true -> :ok
    end
  end

  defp skipped?(token) do
    Regex.match?(~r/^(:|%|\{|\[|-|\d)|[={}"']|\.(py|html|md)$|^[A-Z0-9_]+$/, token)
  end

  defp path_like?(token) do
    String.contains?(token, "/") and not Regex.match?(~r/^[A-Za-z_][\w.]*\/\d+$/, token)
  end

  defp resolve_path(token) do
    in_repo? = Enum.any?(@repo_top_dirs, &String.starts_with?(token, &1 <> "/"))
    found? = @root |> Path.join(token) |> Path.wildcard() |> Enum.any?()
    path_verdict(in_repo?, found? or basename_known?(token))
  end

  defp path_verdict(false, _found?), do: :ok
  defp path_verdict(true, true), do: :ok
  defp path_verdict(true, false), do: :missing_file

  defp basename_known?(token) do
    base = Path.basename(token)
    base != "" and @root |> Path.join("{lib,test,dev,c_src}/**/#{base}") |> Path.wildcard() |> Enum.any?()
  end

  defp resolve_commit(hash) do
    {_out, status} = System.cmd("git", ["-C", @root, "cat-file", "-e", hash <> "^{commit}"], stderr_to_stdout: true)
    if status == 0, do: :ok, else: :missing_commit
  end

  defp resolve_cpp(token) do
    token
    |> String.replace(~r/[(<].*$/, "")
    |> String.split("::", trim: true)
    |> Enum.all?(&word_in?(&1, @cpp_dirs))
    |> verdict(:missing_cpp_symbol)
  end

  defp resolve_elixir_function(token) do
    {name, arity} = split_arity(token)
    {mod_parts, [fun]} = name |> String.split(".") |> Enum.split(-1)

    mod_parts
    |> Enum.join(".")
    |> find_module()
    |> function_verdict(fun, arity)
  end

  defp function_verdict(nil, _fun, _arity), do: :missing_module
  defp function_verdict(mod, fun, arity), do: mod |> exports?(fun, arity) |> verdict(:missing_function)

  defp exports?(mod, fun, arity) do
    (mod.__info__(:functions) ++ mod.__info__(:macros))
    |> Enum.any?(fn {f, a} -> Atom.to_string(f) == fun and arity in [nil, a] end)
    |> or_struct_field?(mod, fun, arity)
  end

  defp or_struct_field?(true, _mod, _fun, _arity), do: true
  defp or_struct_field?(false, _mod, _fun, arity) when arity != nil, do: false

  defp or_struct_field?(false, mod, fun, nil) do
    function_exported?(mod, :__struct__, 0) and Enum.any?(Map.keys(mod.__struct__()), &(Atom.to_string(&1) == fun))
  end

  defp resolve_bare_function(token) do
    {name, arity} = split_arity(token)
    kernel? = exports?(Kernel, name, arity)
    verdict(kernel? or defined_in_repo?(name), :missing_function)
  end

  defp resolve_module_or_cpp(token) do
    verdict(find_module(token) != nil or word_in?(token, @cpp_dirs), :missing_module)
  end

  defp resolve_mix_task(token) do
    verdict(Mix.Task.get(token) != nil, :missing_mix_task)
  end

  defp find_module(name) do
    Enum.find(module_candidates(name), &Code.ensure_loaded?/1)
  end

  defp module_candidates(name) do
    suffix_matches =
      :ex_vrp
      |> Application.spec(:modules)
      |> Enum.filter(&String.ends_with?(Atom.to_string(&1), "." <> name))

    [Module.concat([name]), Module.concat([ExVrp, name]) | suffix_matches]
  end

  defp split_arity(token), do: token |> String.split("/") |> name_and_arity()

  defp name_and_arity([name, arity]), do: {name, String.to_integer(arity)}
  defp name_and_arity([name]), do: {name, nil}

  defp defined_in_repo?(name) do
    pattern = "def(p|macro|macrop)? #{Regex.escape(name)}([ (,]|$)"
    grep?(["-rqE", pattern, "--include=*.ex", "--include=*.exs"], @elixir_dirs)
  end

  defp word_in?(word, dirs), do: grep?(["-rqw", "--", word], dirs)

  defp grep?(args, dirs) do
    {_out, status} = System.cmd("grep", args ++ Enum.map(dirs, &Path.join(@root, &1)), stderr_to_stdout: true)
    status == 0
  end

  defp verdict(true, _kind), do: :ok
  defp verdict(false, kind), do: kind

  defp report(findings) do
    {cites, broken} = Enum.split_with(findings, &match?({:line_cite, _, _, _}, &1))

    Enum.each(Enum.sort(broken), fn {kind, file, line, token} ->
      IO.puts("#{file}:#{line}  #{kind |> Atom.to_string() |> String.replace("_", " ")}: #{token}")
    end)

    IO.puts("\n#{length(broken)} unresolved citation(s)")
    IO.puts("#{length(cites)} line-number citation(s) — prefer `file.ex` + symbol, which does not rot")

    if broken != [], do: System.halt(1)
  end
end

VerifyCitations.run()

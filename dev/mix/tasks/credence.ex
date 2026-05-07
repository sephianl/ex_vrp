defmodule Mix.Tasks.Credence do
  @shortdoc "Run Credence semantic linter on Elixir source files"

  @moduledoc """
  Runs Credence semantic analysis on all Elixir source files.

  By default, only reports issues from fixable rules (those that `mix credence --fix`
  can auto-correct). Use `--all` to include unfixable rules too.

  ## Usage

      mix credence              # Analyze fixable-rule issues only
      mix credence --all        # Analyze all rules (fixable + unfixable)
      mix credence --fix        # Auto-fix fixable issues in place
      mix credence --exit       # Exit with non-zero status if issues found
  """
  use Mix.Task

  @switches [fix: :boolean, exit: :boolean, all: :boolean]
  @credence_opts [phases: [:syntax, :pattern]]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    fixable_rules = fixable_rule_names()

    files = source_files()
    results = Enum.map(files, &process_file(&1, opts, fixable_rules))

    total_issues = results |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    fixed_count = results |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    print_summary(total_issues, fixed_count, opts)

    if opts[:exit] && total_issues > 0 do
      Mix.raise("Credence found #{total_issues} issue(s)")
    end
  end

  defp fixable_rule_names do
    Credence.Pattern.default_rules()
    |> Enum.filter(fn mod ->
      function_exported?(mod, :fixable?, 0) and mod.fixable?()
    end)
    |> MapSet.new(fn mod ->
      mod
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.to_atom()
    end)
  end

  defp source_files do
    ~w(lib test)
    |> Enum.flat_map(&Path.wildcard("#{&1}/**/*.ex"))
    |> Enum.sort()
  end

  defp process_file(path, opts, fixable_rules) do
    code = File.read!(path)

    if opts[:fix] do
      fix_file(path, code)
    else
      analyze_file(path, code, opts, fixable_rules)
    end
  rescue
    e ->
      Mix.shell().error("  #{path}: error — #{Exception.message(e)}")
      {path, 0, 0}
  end

  defp analyze_file(path, code, opts, fixable_rules) do
    case Credence.analyze(code, @credence_opts) do
      %{valid: true} ->
        {path, 0, 0}

      %{issues: issues} ->
        filtered =
          if opts[:all] do
            issues
          else
            Enum.filter(issues, &MapSet.member?(fixable_rules, &1.rule))
          end

        Enum.each(filtered, &print_issue(path, &1))
        {path, length(filtered), 0}
    end
  end

  defp fix_file(path, code) do
    case Credence.fix(code, @credence_opts) do
      %{code: ^code, issues: issues} ->
        Enum.each(issues, &print_issue(path, &1))
        {path, length(issues), 0}

      %{code: fixed, issues: remaining} ->
        File.write!(path, fixed)
        Enum.each(remaining, &print_issue(path, &1))
        {path, length(remaining), max(count_original_issues(code) - length(remaining), 0)}
    end
  end

  defp count_original_issues(code) do
    case Credence.analyze(code, @credence_opts) do
      %{issues: issues} -> length(issues)
      _ -> 0
    end
  end

  defp print_issue(path, %{rule: rule, message: message, meta: meta}) do
    line = if meta[:line], do: ":#{meta[:line]}", else: ""
    Mix.shell().info("  #{path}#{line}: [#{rule}] #{String.trim(message)}")
  end

  defp print_issue(path, %{rule: rule, message: message}) do
    Mix.shell().info("  #{path}: [#{rule}] #{String.trim(message)}")
  end

  defp print_summary(total_issues, fixed_count, opts) do
    cond do
      total_issues == 0 && fixed_count == 0 ->
        Mix.shell().info("Credence: no issues found")

      opts[:fix] && fixed_count > 0 ->
        Mix.shell().info("Credence: fixed #{fixed_count} issue(s), #{total_issues} remaining")

      true ->
        Mix.shell().info("Credence: #{total_issues} issue(s) found")
    end
  end
end

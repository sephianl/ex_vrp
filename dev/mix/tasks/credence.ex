defmodule Mix.Tasks.Credence do
  @shortdoc "Run Credence semantic linter on Elixir source files"

  @moduledoc """
  Runs Credence semantic analysis on all Elixir source files.

  ## Usage

      mix credence              # Analyze and report all issues
      mix credence --exit       # Exit with non-zero status if issues found
      mix credence --fix        # Apply autofixes and write files in place
  """
  use Mix.Task

  @switches [exit: :boolean, fix: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)
    if opts[:fix], do: run_fix(opts), else: run_analyze(opts)
  end

  defp run_analyze(opts) do
    total_issues = Enum.sum_by(source_files(), &analyze_file/1)

    if total_issues == 0 do
      Mix.shell().info("Credence: no issues found")
    else
      Mix.shell().info("Credence: #{total_issues} issue(s) found")
    end

    if opts[:exit] && total_issues > 0 do
      Mix.raise("Credence found #{total_issues} issue(s)")
    end
  end

  defp run_fix(opts) do
    {total_applied, total_remaining} =
      Enum.reduce(source_files(), {0, 0}, fn path, {applied_acc, remaining_acc} ->
        {applied, remaining} = fix_file(path)
        {applied_acc + applied, remaining_acc + remaining}
      end)

    Mix.shell().info("Credence fix: applied #{total_applied} fix(es), #{total_remaining} issue(s) remain")

    if opts[:exit] && total_remaining > 0 do
      Mix.raise("Credence found #{total_remaining} unfixable issue(s)")
    end
  end

  defp fix_file(path) do
    original = File.read!(path)
    %{code: fixed, issues: remaining, applied_rules: applied} = apply(Credence, :fix, [original])

    if fixed != original do
      File.write!(path, fixed)
      Mix.shell().info("  #{path}: applied #{length(applied)} fix(es)")
    end

    Enum.each(remaining, &print_issue(path, &1))
    {length(applied), length(remaining)}
  rescue
    e ->
      Mix.shell().error("  #{path}: error — #{Exception.message(e)}")
      {0, 0}
  end

  defp source_files do
    ~w(lib test dev)
    |> Enum.flat_map(&Path.wildcard("#{&1}/**/*.ex"))
    |> Enum.sort()
  end

  defp analyze_file(path) do
    code = File.read!(path)

    case apply(Credence, :analyze, [code]) do
      %{valid: true} ->
        0

      %{issues: issues} ->
        Enum.each(issues, &print_issue(path, &1))
        length(issues)
    end
  rescue
    e ->
      Mix.shell().error("  #{path}: error — #{Exception.message(e)}")
      0
  end

  defp print_issue(path, %{rule: rule, message: message, meta: meta}) do
    line = if meta[:line], do: ":#{meta[:line]}", else: ""
    Mix.shell().info("  #{path}#{line}: [#{rule}] #{String.trim(message)}")
  end

  defp print_issue(path, %{rule: rule, message: message}) do
    Mix.shell().info("  #{path}: [#{rule}] #{String.trim(message)}")
  end
end

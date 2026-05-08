defmodule Mix.Tasks.Credence do
  @shortdoc "Run Credence semantic linter on Elixir source files"

  @moduledoc """
  Runs Credence semantic analysis on all Elixir source files.

  ## Usage

      mix credence              # Analyze and report all issues
      mix credence --exit       # Exit with non-zero status if issues found
  """
  use Mix.Task

  @switches [exit: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)
    run_analyze(opts)
  end

  defp run_analyze(opts) do
    total_issues =
      source_files()
      |> Enum.map(&analyze_file/1)
      |> Enum.sum()

    if total_issues == 0 do
      Mix.shell().info("Credence: no issues found")
    else
      Mix.shell().info("Credence: #{total_issues} issue(s) found")
    end

    if opts[:exit] && total_issues > 0 do
      Mix.raise("Credence found #{total_issues} issue(s)")
    end
  end

  defp source_files do
    ~w(lib test)
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

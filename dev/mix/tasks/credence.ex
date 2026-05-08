defmodule Mix.Tasks.Credence do
  @shortdoc "Run Credence semantic linter on Elixir source files"

  @moduledoc """
  Runs Credence semantic analysis on all Elixir source files.

  ## Usage

      mix credence              # Analyze and report all issues
      mix credence --fix        # Auto-fix, format, compile-verify, revert broken
      mix credence --exit       # Exit with non-zero status if issues found
  """
  use Mix.Task

  @switches [exit: :boolean, fix: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    if opts[:fix] do
      run_fix()
    else
      run_analyze(opts)
    end
  end

  defp run_fix do
    files = source_files()
    originals = Map.new(files, fn path -> {path, File.read!(path)} end)

    changed = apply_fixes(files, originals)

    if changed == [] do
      Mix.shell().info("Credence: no fixable issues found")
    else
      Mix.Task.rerun("format", changed)
      reverted = revert_broken(changed, originals)
      report_fix_results(changed, reverted)
    end
  end

  defp apply_fixes(files, originals) do
    Enum.filter(files, fn path ->
      try do
        original = originals[path]

        case Credence.fix(original) do
          %{code: ^original} -> false
          %{code: fixed} -> File.write!(path, fixed) || true
        end
      rescue
        _ -> false
      end
    end)
  end

  defp revert_broken(changed, originals) do
    parse_broken =
      Enum.filter(changed, fn path ->
        content = File.read!(path)

        case Code.string_to_quoted(content) do
          {:ok, _} -> false
          {:error, _} -> true
        end
      end)

    Enum.each(parse_broken, &File.write!(&1, originals[&1]))

    compile_broken = revert_until_clean(changed -- parse_broken, originals)

    parse_broken ++ compile_broken
  end

  defp revert_until_clean(candidates, originals, reverted \\ []) do
    if candidates == [] do
      reverted
    else
      {output, status} =
        System.cmd("mix", ["compile", "--no-deps-check"], stderr_to_stdout: true)

      if status == 0 do
        reverted
      else
        broken = extract_error_files(output, candidates)

        if broken == [] do
          reverted
        else
          Enum.each(broken, &File.write!(&1, originals[&1]))
          revert_until_clean(candidates -- broken, originals, reverted ++ broken)
        end
      end
    end
  end

  defp extract_error_files(output, candidates) do
    candidate_set = MapSet.new(candidates)

    ~r"└─ ([^:\s]+\.ex)"
    |> Regex.scan(output)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(candidate_set, &1))
  end

  defp report_fix_results(changed, reverted) do
    fixed_count = length(changed) - length(reverted)

    Enum.each(reverted, fn path ->
      Mix.shell().error("  #{path}: reverted (fix broke compilation)")
    end)

    if fixed_count > 0, do: Mix.shell().info("Credence: fixed #{fixed_count} file(s)")
    if reverted != [], do: Mix.shell().error("Credence: reverted #{length(reverted)} file(s)")
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

    case Credence.analyze(code) do
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

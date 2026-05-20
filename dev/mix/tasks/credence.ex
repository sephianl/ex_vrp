defmodule Mix.Tasks.Credence.Finding do
  @moduledoc false

  @derive Jason.Encoder
  @enforce_keys [:rule, :message, :file, :fingerprint]
  defstruct [:rule, :message, :file, :line, :fingerprint]

  def build(path, %{rule: rule, message: message, meta: meta}) do
    line = line_from_meta(meta)

    %__MODULE__{
      rule: to_string(rule),
      message: String.trim(message),
      file: path,
      line: line,
      fingerprint: fingerprint(rule, path, line, message)
    }
  end

  defp line_from_meta(%{line: line}) when is_integer(line), do: line
  defp line_from_meta(_), do: nil

  defp fingerprint(rule, file, line, message) do
    input = [to_string(rule), to_string(file), to_string(line), message]
    digest = :crypto.hash(:sha256, Enum.join(input, "\0"))
    "sha256:" <> Base.encode16(digest, case: :lower)
  end
end

defmodule Mix.Tasks.Credence.Baseline do
  @moduledoc false

  alias Mix.Tasks.Credence.Finding

  @derive Jason.Encoder
  defstruct version: 1, tool: "credence", findings: []

  def filter(findings, nil), do: {findings, []}

  def filter(findings, path) do
    known = MapSet.new(read(path).findings, & &1.fingerprint)
    Enum.split_with(findings, &(!MapSet.member?(known, &1.fingerprint)))
  end

  def write(path, findings) do
    baseline = %__MODULE__{findings: Enum.sort_by(findings, &sort_key/1)}
    File.write!(path, Jason.encode!(baseline, pretty: true) <> "\n")
  end

  def read(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!(keys: :atoms)
      |> from_map()
    else
      %__MODULE__{}
    end
  end

  defp from_map(%{findings: findings} = data) do
    %__MODULE__{
      version: Map.get(data, :version, 1),
      tool: Map.get(data, :tool, "credence"),
      findings: Enum.map(findings, &finding_from_map/1)
    }
  end

  defp finding_from_map(data) do
    %Finding{
      rule: Map.fetch!(data, :rule),
      message: Map.get(data, :message),
      file: Map.get(data, :file),
      line: Map.get(data, :line),
      fingerprint: Map.fetch!(data, :fingerprint)
    }
  end

  defp sort_key(%Finding{file: file, line: line, rule: rule}), do: {to_string(file), line || 0, to_string(rule)}
end

defmodule Mix.Tasks.Credence do
  @shortdoc "Run Credence semantic linter on Elixir source files"

  @moduledoc """
  Runs Credence semantic analysis on all Elixir source files.

  ## Usage

      mix credence                              # Analyze and report all issues
      mix credence --exit                       # Exit non-zero if findings remain
      mix credence --fix                        # Apply autofixes in place
      mix credence --baseline PATH              # Ignore findings recorded in PATH
      mix credence --write-baseline PATH        # Snapshot current findings to PATH
  """
  use Mix.Task

  alias Mix.Tasks.Credence.Baseline
  alias Mix.Tasks.Credence.Finding

  @switches [
    exit: :boolean,
    fix: :boolean,
    baseline: :string,
    write_baseline: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)
    if opts[:fix], do: run_fix(opts), else: run_analyze(opts)
  end

  defp run_analyze(opts) do
    findings = Enum.flat_map(source_files(), &collect_findings/1)
    {new_findings, known_findings} = Baseline.filter(findings, opts[:baseline])

    Enum.each(new_findings, &print_finding/1)

    if path = opts[:write_baseline] do
      Baseline.write(path, findings)
      Mix.shell().info("Credence: wrote #{length(findings)} finding(s) to #{path}")
    end

    summarize_analyze(new_findings, known_findings)

    if opts[:exit] && new_findings != [] do
      Mix.raise("Credence found #{length(new_findings)} new finding(s)")
    end
  end

  defp summarize_analyze([], []), do: Mix.shell().info("Credence: no issues found")

  defp summarize_analyze([], known), do: Mix.shell().info("Credence: no new findings (#{length(known)} baselined)")

  defp summarize_analyze(new, []), do: Mix.shell().info("Credence: #{length(new)} finding(s)")

  defp summarize_analyze(new, known),
    do: Mix.shell().info("Credence: #{length(new)} new finding(s) (#{length(known)} baselined)")

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

    Enum.each(remaining, fn issue -> print_finding(Finding.build(path, issue)) end)
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

  defp collect_findings(path) do
    code = File.read!(path)

    case apply(Credence, :analyze, [code]) do
      %{valid: true} -> []
      %{issues: issues} -> Enum.map(issues, &Finding.build(path, &1))
    end
  rescue
    e ->
      Mix.shell().error("  #{path}: error — #{Exception.message(e)}")
      []
  end

  defp print_finding(%Finding{file: file, line: line, rule: rule, message: message}) do
    location = if line, do: "#{file}:#{line}", else: file
    Mix.shell().info("  #{location}: [#{rule}] #{String.trim(message)}")
  end
end

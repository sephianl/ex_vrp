defmodule ExVrp.ABBenchmark.Checkout do
  @moduledoc """
  The git branch and commit a benchmark ran on, recorded in its results; `"unknown"`
  outside a git checkout.
  """

  @spec branch() :: String.t()
  def branch, do: git_output(["rev-parse", "--abbrev-ref", "HEAD"])

  @spec commit() :: String.t()
  def commit, do: git_output(["rev-parse", "--short", "HEAD"])

  defp git_output(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  end
end

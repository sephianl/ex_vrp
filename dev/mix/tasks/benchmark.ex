defmodule Mix.Tasks.Benchmark do
  @shortdoc "Run VRP benchmarks with regression detection"

  @moduledoc """
  Run benchmarks on VRPLIB instances and check for quality regressions.

  Runs each instance with multiple seeds (42, 1, 1337). Checks seed=42
  distance against expected values and verifies all seeds produce feasible
  solutions.

  ## Usage

      mix benchmark                       # Run all instances
      mix benchmark --set rc208           # Run specific instance
      mix benchmark --quick               # Quick subset (ok_small, e_n22_k4)
      mix benchmark --iterations 500      # Custom iteration count
      mix benchmark --save results.json   # Save results to file

  ## Available instances

  - ok_small, e_n22_k4, rc208, pr11a, c201, x101, x115, pr01, pr107, p06, small_vrpspd, gtsp
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          set: :keep,
          quick: :boolean,
          iterations: :integer,
          save: :string
        ]
      )

    Application.ensure_all_started(:ex_vrp)

    instances = determine_instances(opts)
    iterations = Keyword.get(opts, :iterations, 1000)

    ExVrp.Benchmark.run(instances, iterations: iterations, save: opts[:save])
  end

  defp determine_instances(opts) do
    cond do
      opts[:quick] -> [:ok_small, :e_n22_k4]
      opts[:set] -> opts |> Keyword.get_values(:set) |> Enum.map(&String.to_atom/1)
      true -> :all
    end
  end
end

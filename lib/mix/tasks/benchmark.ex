defmodule Mix.Tasks.Benchmark do
  @moduledoc """
  Run benchmarks on VRPLIB instances.

  ## Usage

      mix benchmark                    # Run all instances
      mix benchmark --set rc208        # Run specific instance
      mix benchmark --set rc208 --set ok_small  # Multiple instances
      mix benchmark --quick            # Quick subset (ok_small, e_n22_k4)
      mix benchmark --iterations 100   # Custom iteration count
      mix benchmark --save results.json # Save results to file

  ## Available instance sets

  - ok_small, e_n22_k4, rc208, pr11a, c201, x101, x115, pr01, pr107, p06, small_vrpspd, gtsp
  """
  use Mix.Task

  @shortdoc "Run VRP benchmarks"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          set: :keep,
          quick: :boolean,
          all: :boolean,
          iterations: :integer,
          save: :string
        ]
      )

    Application.ensure_all_started(:ex_vrp)

    instances = determine_instances(opts)
    iterations = Keyword.get(opts, :iterations, 100)

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

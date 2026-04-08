defmodule ExVrp.BenchmarkRegressionTest do
  use ExUnit.Case, async: false

  alias ExVrp.Benchmark
  alias ExVrp.Read
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :benchmark

  @data_dir Path.join(:code.priv_dir(:ex_vrp), "benchmark_data")
  @iterations 1000
  @seeds [42, 1, 1337]

  @instances %{
    small_vrpspd: {"SmallVRPSPD.vrp", :round},
    ok_small: {"OkSmall.txt", :none},
    e_n22_k4: {"E-n22-k4.txt", :dimacs},
    p06: {"p06-2-50.vrp", :dimacs},
    pr01: {"PR01.vrp", :none},
    pr107: {"pr107.tsp", :dimacs},
    rc208: {"RC208.vrp", :dimacs},
    x101: {"X-n101-50-k13.vrp", :round},
    gtsp: {"50pr439.gtsp", :round},
    c201: {"C201R0.25.vrp", :dimacs},
    x115: {"X115-HVRP.vrp", :exact},
    pr11a: {"PR11A.vrp", :trunc}
  }

  for {name, {file, round_func}} <- @instances do
    @tag instance: name
    test "#{name} quality across seeds" do
      expected = Benchmark.expected_distances()[unquote(name)]
      path = Path.join(@data_dir, unquote(file))
      model = Read.read(path, round_func: unquote(round_func))

      for seed <- @seeds do
        stop = StoppingCriteria.max_iterations(@iterations)
        {:ok, result} = Solver.solve(model, stop: stop, seed: seed, num_starts: 1)

        assert result.best.is_feasible,
               "#{unquote(name)} seed=#{seed}: solution is infeasible"

        if seed == 42 and expected do
          assert result.best.distance == expected,
                 "#{unquote(name)} seed=42: distance #{result.best.distance} != expected #{expected}"
        end
      end
    end
  end
end

defmodule Mix.Tasks.BenchmarkTest do
  use ExUnit.Case, async: true

  # Test the determine_instances logic by calling the task with various options
  # Since the task uses IO and actually runs benchmarks, we can't easily test the run/1 function
  # Instead, we test that the module is defined and has the expected structure

  alias Mix.Tasks.Benchmark

  describe "task structure" do
    test "task module is defined" do
      assert Code.ensure_loaded?(Benchmark)
    end

    test "task implements Mix.Task behaviour" do
      behaviours = Benchmark.__info__(:attributes)[:behaviour] || []
      assert Mix.Task in behaviours
    end

    test "task has shortdoc" do
      # Mix tasks with @shortdoc will be listed in `mix help`
      assert Mix.Task.shortdoc(Benchmark)
    end
  end
end

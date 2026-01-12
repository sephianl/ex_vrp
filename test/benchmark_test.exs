defmodule ExVrp.BenchmarkTest do
  use ExUnit.Case, async: true

  alias ExVrp.Benchmark

  describe "available_instances/0" do
    test "returns a non-empty list of atoms" do
      instances = Benchmark.available_instances()

      assert is_list(instances)
      assert instances != []
      assert Enum.all?(instances, &is_atom/1)
    end

    test "includes known instances" do
      instances = Benchmark.available_instances()

      # These should be present based on the @instances map
      assert :ok_small in instances
      assert :rc208 in instances
      assert :e_n22_k4 in instances
    end

    test "returns expected number of instances" do
      instances = Benchmark.available_instances()

      # Based on @instances module attribute, there are 12 instances
      assert length(instances) == 12
    end
  end
end

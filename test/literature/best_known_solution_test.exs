defmodule ExVrp.Literature.BestKnownSolutionTest do
  use ExUnit.Case, async: true

  alias ExVrp.Literature.BestKnownSolution
  alias ExVrp.Read

  @data_dir Path.join(:code.priv_dir(:ex_vrp), "benchmark_data")

  describe "parse/1" do
    test "reads routes, the stated cost with or without a colon, and optimality" do
      assert BestKnownSolution.parse("Route #1: 3 1\nRoute #2:\nRoute #3: 2\nCost: 15006\nOptimal: True\n") ==
               %BestKnownSolution{routes: [{1, [3, 1]}, {2, []}, {3, [2]}], stated_cost: 15_006.0, optimal: true}

      assert %BestKnownSolution{stated_cost: 827.3, optimal: nil} = BestKnownSolution.parse("Route #1: 1\nCost 827.3\n")
    end
  end

  describe "evaluate/2" do
    @describetag :nif_required

    test "a depot inside a route is a reload there" do
      model = Read.read(Path.join(@data_dir, "OkSmallMultipleReloadDepots.txt"))
      solution = BestKnownSolution.parse("Route #1: 3 4 1 2\n")

      assert BestKnownSolution.evaluate(solution, model) == {:ok, 1931 + 818 + 1594 + 1992 + 1965}
    end

    test "a solution that breaks the model's constraints is an error" do
      model = Read.read(Path.join(@data_dir, "OkSmall.txt"))

      assert {:error, _reason} = BestKnownSolution.evaluate(%BestKnownSolution{routes: [{1, [1, 2, 3, 4]}]}, model)
    end
  end
end

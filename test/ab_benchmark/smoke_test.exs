defmodule ExVrp.ABBenchmark.SmokeTest do
  use ExUnit.Case, async: true

  alias ExVrp.ABBenchmark.Smoke

  defp results(instances), do: %{"instances" => instances}

  defp inst(bks, feasible_count, mean_objective) do
    %{"bks" => bks, "feasible_count" => feasible_count, "mean_objective" => mean_objective}
  end

  test "no violations when feasible and within the gap ceiling" do
    r = results(%{"a" => inst(100, 1, 104.0)})
    assert Smoke.violations(r, 0.05) == []
  end

  test "flags an infeasible instance" do
    r = results(%{"a" => inst(100, 0, nil)})
    assert [msg] = Smoke.violations(r, 0.05)
    assert msg =~ "no feasible solution"
  end

  test "flags an instance over the gap ceiling" do
    r = results(%{"a" => inst(100, 1, 110.0)})
    assert [msg] = Smoke.violations(r, 0.05)
    assert msg =~ "exceeds ceiling"
  end

  test "ignores gap for instances without a BKS" do
    r = results(%{"a" => inst(nil, 1, 9_999_999.0)})
    assert Smoke.violations(r, 0.05) == []
  end

  test "gap exactly at the ceiling does not violate" do
    r = results(%{"a" => inst(100, 1, 105.0)})
    assert Smoke.violations(r, 0.05) == []
  end
end

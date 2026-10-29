defmodule ExVrp.ErrorsTest do
  use ExUnit.Case, async: true

  alias ExVrp.SolveError

  describe "SolveError" do
    test "message with binary reason" do
      error = %SolveError{reason: "No feasible solution found"}
      message = Exception.message(error)

      assert message =~ "Solver failed"
      assert message =~ "No feasible solution found"
    end

    test "message with non-binary reason" do
      error = %SolveError{reason: {:timeout, 5000}}
      message = Exception.message(error)

      assert message =~ "Solver failed"
      assert message =~ "{:timeout, 5000}"
    end

    test "message lists validation messages one per indented line" do
      error = %SolveError{reason: ["a is bad", "b is missing"]}

      assert Exception.message(error) == "Solver failed:\n  - a is bad\n  - b is missing"
    end

    test "can be raised with reason" do
      assert_raise SolveError, ~r/test reason/, fn ->
        raise SolveError, reason: "test reason"
      end
    end
  end
end

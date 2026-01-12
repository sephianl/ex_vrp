defmodule ExVrp.ErrorsTest do
  use ExUnit.Case, async: true

  alias ExVrp.NotImplementedError
  alias ExVrp.SolveError
  alias ExVrp.ValidationError

  describe "NotImplementedError" do
    test "message includes function name" do
      error = %NotImplementedError{function: "some_nif_function"}
      message = Exception.message(error)

      assert message =~ "some_nif_function"
      assert message =~ "not yet implemented"
    end

    test "can be raised with function name" do
      assert_raise NotImplementedError, ~r/test_function/, fn ->
        raise NotImplementedError, function: "test_function"
      end
    end
  end

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

    test "can be raised with reason" do
      assert_raise SolveError, ~r/test reason/, fn ->
        raise SolveError, reason: "test reason"
      end
    end
  end

  describe "ValidationError" do
    test "message with single error" do
      error = %ValidationError{errors: ["Missing depot"]}
      message = Exception.message(error)

      assert message =~ "Model validation failed"
      assert message =~ "Missing depot"
    end

    test "message with multiple errors" do
      error = %ValidationError{
        errors: [
          "Missing depot",
          "Invalid vehicle capacity",
          "Client delivery exceeds capacity"
        ]
      }

      message = Exception.message(error)

      assert message =~ "Model validation failed"
      assert message =~ "Missing depot"
      assert message =~ "Invalid vehicle capacity"
      assert message =~ "Client delivery exceeds capacity"
    end

    test "errors are formatted as bullet points" do
      error = %ValidationError{errors: ["Error 1", "Error 2"]}
      message = Exception.message(error)

      # Check each error is on its own line with a dash
      assert message =~ "- Error 1"
      assert message =~ "- Error 2"
    end

    test "can be raised with errors list" do
      assert_raise ValidationError, ~r/validation failed/, fn ->
        raise ValidationError, errors: ["Test error"]
      end
    end
  end
end

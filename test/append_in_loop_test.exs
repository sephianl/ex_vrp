defmodule CredoChecks.AppendInLoopTest do
  use ExUnit.Case, async: true

  alias Credo.SourceFile

  @check CredoChecks.AppendInLoop

  defp issues(code) do
    code
    |> SourceFile.parse("test.ex")
    |> @check.run([])
  end

  describe "Enum.reduce" do
    test "flags ++ inside Enum.reduce" do
      [issue] =
        issues("""
        defmodule Foo do
          def bar(list) do
            Enum.reduce(list, [], fn item, acc ->
              acc ++ [item]
            end)
          end
        end
        """)

      assert issue.check == @check
      assert issue.trigger == "++"
    end

    test "ignores prepend [item] ++ list inside Enum.reduce" do
      assert [] ==
               issues("""
               defmodule Foo do
                 def bar(list) do
                   Enum.reduce(list, [], fn item, acc ->
                     [item] ++ acc
                   end)
                 end
               end
               """)
    end
  end

  describe "for/reduce" do
    test "flags ++ inside for/reduce" do
      [_issue] =
        issues("""
        defmodule Foo do
          def bar(list) do
            for item <- list, reduce: [] do
              acc -> acc ++ [item]
            end
          end
        end
        """)
    end
  end

  describe "List.foldl/foldr" do
    test "flags ++ inside List.foldl" do
      [_issue] =
        issues("""
        defmodule Foo do
          def bar(list) do
            List.foldl(list, [], fn item, acc ->
              acc ++ [item]
            end)
          end
        end
        """)
    end
  end

  describe "recursive functions" do
    test "flags ++ inside recursive function" do
      [_issue] =
        issues("""
        defmodule Foo do
          def collect([head | tail], acc) do
            collect(tail, acc ++ [head])
          end

          def collect([], acc), do: acc
        end
        """)
    end
  end

  describe "no false positives" do
    test "ignores ++ outside loops" do
      assert [] ==
               issues("""
               defmodule Foo do
                 def bar(a, b), do: a ++ b
               end
               """)
    end

    test "ignores [item | acc] prepend in reduce" do
      assert [] ==
               issues("""
               defmodule Foo do
                 def bar(list) do
                   Enum.reduce(list, [], fn item, acc ->
                     [item | acc]
                   end)
                 end
               end
               """)
    end
  end
end

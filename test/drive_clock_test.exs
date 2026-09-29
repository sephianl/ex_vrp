defmodule ExVrp.DriveClockTest do
  @moduledoc """
  `DriveClock` folds driving since the last break over a route. A token list
  reads in route order: `{:leg, drive}` drives to the next real node, and a
  `:break` sits on the leg after it. The brute walk applies the spec's rule
  directly; the fold must agree with it however the route is cut.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExVrp.Native

  @moduletag :nif_required

  @limit 270

  defp fold(tokens), do: Native.drive_clock_fold_nif(tokens, @limit)

  defp leg, do: map(integer(0..400), &{:leg, &1})

  defp route_tokens do
    gen all(
          first <- leg(),
          rest <- list_of(tuple({integer(0..3), leg()}), max_length: 7)
        ) do
      [first | Enum.flat_map(rest, fn {breaks, leg} -> List.duplicate(:break, breaks) ++ [leg] end)]
    end
  end

  property "the fold equals the brute walk, split anywhere" do
    check all(tokens <- route_tokens(), split <- integer(0..length(tokens)), max_runs: 2_000) do
      expected = Native.drive_clock_brute_nif(tokens, @limit)

      assert Native.drive_clock_fold_nif(tokens, @limit) == expected
      assert Native.drive_clock_fold_split_nif(tokens, split, @limit) == expected
    end
  end

  test "hand cases" do
    assert fold([{:leg, 300}]) == 30
    assert fold([{:leg, 0}, :break, {:leg, 300}]) == 30
    assert fold([{:leg, 0}, :break, :break, {:leg, 300}]) == 0
    assert fold([{:leg, 200}, :break, {:leg, 100}]) == 0
    assert fold([{:leg, 200}, {:leg, 100}]) == 30
  end
end

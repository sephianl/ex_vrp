defmodule ExVrp.DriveClockTest do
  @moduledoc """
  `DriveClock` folds driving (or work) since the last break over a route. A
  token list reads in route order: `{:leg, drive}` drives to the next real
  node, `{:stop, service}` is service at the node reached last (or the start
  node), and a `:break` sits on the leg after it. The drive clock ignores
  service; the work clock counts it. The brute walk applies the spec's rule
  directly; the fold must agree with it however the route is cut.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExVrp.Native

  @moduletag :nif_required

  @limit 270

  defp fold(tokens, quantity \\ :drive), do: Native.drive_clock_fold_nif(tokens, quantity, @limit)

  defp leg, do: map(integer(0..400), &{:leg, &1})

  defp stops, do: map(list_of(integer(0..150), max_length: 1), fn services -> Enum.map(services, &{:stop, &1}) end)

  defp route_tokens do
    gen all(
          start <- stops(),
          lead <- integer(0..2),
          first <- leg(),
          first_stops <- stops(),
          rest <- list_of(tuple({integer(0..3), leg(), stops()}), max_length: 7)
        ) do
      start ++
        List.duplicate(:break, lead) ++
        [first | first_stops] ++
        Enum.flat_map(rest, fn {breaks, leg, stops} -> List.duplicate(:break, breaks) ++ [leg | stops] end)
    end
  end

  property "the fold equals the brute walk, split anywhere, for both quantities" do
    check all(
            tokens <- route_tokens(),
            split <- integer(0..length(tokens)),
            quantity <- member_of([:drive, :work]),
            max_runs: 2_000
          ) do
      expected = Native.drive_clock_brute_nif(tokens, quantity, @limit)

      assert Native.drive_clock_fold_nif(tokens, quantity, @limit) == expected
      assert Native.drive_clock_fold_split_nif(tokens, split, quantity, @limit) == expected
    end
  end

  test "hand cases" do
    assert fold([{:leg, 300}]) == 30
    assert fold([{:leg, 0}, :break, {:leg, 300}]) == 30
    assert fold([{:leg, 0}, :break, :break, {:leg, 300}]) == 0
    assert fold([{:leg, 200}, :break, {:leg, 100}]) == 0
    assert fold([{:leg, 200}, {:leg, 100}]) == 30
    assert fold([:break, {:leg, 300}]) == 30
  end

  test "work counts service, drive does not" do
    tokens = [{:leg, 200}, {:stop, 50}, {:leg, 50}]

    # Drive: 200 + 50 = 250. Work: 200 + 50 + 50 = 300, 30 over.
    assert fold(tokens, :drive) == 0
    assert fold(tokens, :work) == 30

    # A break on the last leg closes the stretch after the stop's service:
    # 200 + 100 = 300 before it.
    assert fold([{:leg, 200}, {:stop, 100}, :break, {:leg, 50}], :work) == 30

    # Service at the start node is a carry-in; at the last node, work after end.
    assert fold([{:stop, 100}, {:leg, 200}], :work) == 30
    assert fold([{:leg, 0}, :break, {:leg, 200}, {:stop, 100}], :work) == 30
  end
end

defmodule ExVrp.DriveClockTest do
  @moduledoc """
  `DriveClock` folds driving (or work) since the last break over a route. A
  token list reads in route order: `{:leg, drive}` drives to the next real
  node, `{:stop, service}` is service at the node reached last (or the start
  node), and a `:break` sits on the leg after it. The drive clock ignores
  service; the work clock counts it. Each fold answers `{overrun, missing}`:
  the clipped time past the limit, and the breaks the stretches still lack,
  ceil(stretch / limit) - 1 for each. The brute walk applies the spec's rule
  directly: a break is taken along its leg once the stretch reaches the limit.

  The fold must agree with it from the route's start, but not cut anywhere:
  how much of a leg fits before its break depends on the stretch the leg
  continues, so a second part folded on its own merges exactly only while it
  holds no break of its own. The search extends a clock through such parts
  instead (covered by `break_nodes_test.exs` and SANITIZE's asserts).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExVrp.Native

  @moduletag :nif_required

  @limit 270

  defp fold(tokens, quantity \\ :drive) do
    {overrun, _missing} = Native.drive_clock_fold_nif(tokens, quantity, @limit)
    overrun
  end

  defp missing(tokens, quantity \\ :drive) do
    {_overrun, missing} = Native.drive_clock_fold_nif(tokens, quantity, @limit)
    missing
  end

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

  property "the fold equals the brute walk, for both quantities" do
    check all(
            tokens <- route_tokens(),
            quantity <- member_of([:drive, :work]),
            max_runs: 2_000
          ) do
      assert Native.drive_clock_fold_nif(tokens, quantity, @limit) ==
               Native.drive_clock_brute_nif(tokens, quantity, @limit)
    end
  end

  property "a split merges back exactly when the second part holds no break" do
    check all(
            tokens <- route_tokens(),
            split <- integer(last_break(tokens)..length(tokens)),
            quantity <- member_of([:drive, :work]),
            max_runs: 2_000
          ) do
      assert Native.drive_clock_fold_split_nif(tokens, split, quantity, @limit) ==
               Native.drive_clock_brute_nif(tokens, quantity, @limit)
    end
  end

  # Breaks from the split up to the leg joining the parts sit on that leg, so
  # a split at or after the last break leaves the second part none of its own.
  defp last_break(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.filter(&match?({:break, _index}, &1))
    |> Enum.map(&elem(&1, 1))
    |> Enum.max(fn -> 0 end)
  end

  test "hand cases" do
    assert fold([{:leg, 300}]) == 30
    assert fold([{:leg, 0}, :break, :break, {:leg, 300}]) == 0
    assert fold([{:leg, 200}, :break, {:leg, 100}]) == 0
    assert fold([{:leg, 200}, {:leg, 100}]) == 30
  end

  test "a break is taken along its leg once the stretch reaches the limit" do
    assert fold([{:leg, 0}, :break, {:leg, 300}]) == 0
    assert fold([:break, {:leg, 300}]) == 0
    assert fold([:break, {:leg, 600}]) == 60
    assert fold([:break, :break, {:leg, 600}]) == 0

    # 150 carried in leaves 120 of the leg before the break, so 30 after it.
    assert fold([{:leg, 150}, :break, {:leg, 150}, {:leg, 150}]) == 0
    assert missing([{:leg, 150}, :break, {:leg, 150}, {:leg, 250}]) == 1

    # A stretch already over the limit gets nothing of the leg before its break.
    assert fold([{:leg, 300}, :break, {:leg, 100}]) == 30
  end

  test "missing breaks, per stretch" do
    assert missing([{:leg, 270}]) == 0
    assert missing([{:leg, 300}]) == 1
    assert missing([{:leg, 600}]) == 2
    assert missing([{:leg, 300}, :break, {:leg, 300}]) == 2
    assert missing([{:leg, 0}, :break, :break, {:leg, 300}]) == 0
    assert missing([{:leg, 200}, {:stop, 100}, {:leg, 50}], :work) == 1
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
    assert fold([{:leg, 0}, {:leg, 200}, {:stop, 100}], :work) == 30

    # A break never falls inside service: 200 of the leg fits before it, and
    # the 100 of service comes after.
    assert fold([{:leg, 0}, :break, {:leg, 200}, {:stop, 100}], :work) == 0
  end
end

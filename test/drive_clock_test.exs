defmodule ExVrp.DriveClockTest do
  @moduledoc """
  `BreakClocks` folds driving and work since the last break over a route. A
  token list reads in route order: `{:leg, drive}` drives to the next real
  node, `{:stop, service}` is service at the node reached last (or the start
  node), and a `:break` sits on the leg after it. The drive clock ignores
  service; the work clock counts it. Each fold answers `{overrun, missing}`
  per clock: the clipped time past the limit, and the breaks the stretches
  still lack, ceil(stretch / limit) - 1 for each. The brute walk applies the
  spec's rule directly: a break is taken along its leg once either clock
  reaches its limit, and stops both.

  The fold must agree with it from the route's start, but not cut anywhere:
  where a break falls on its leg depends on the stretches the leg continues,
  so a second part folded on its own merges exactly only while it holds no
  break of its own. The search extends the clocks through such parts instead
  (covered by `break_nodes_test.exs` and SANITIZE's asserts).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExVrp.Native

  @moduletag :nif_required

  @limit 270
  @unbounded 9_223_372_036_854_775_807

  defp fold(tokens, quantity \\ :drive) do
    {overrun, _missing} = answer(tokens, quantity)
    overrun
  end

  defp missing(tokens, quantity \\ :drive) do
    {_overrun, missing} = answer(tokens, quantity)
    missing
  end

  defp answer(tokens, :drive), do: tokens |> Native.drive_clock_fold_nif(@limit, @unbounded) |> elem(0)
  defp answer(tokens, :work), do: tokens |> Native.drive_clock_fold_nif(@unbounded, @limit) |> elem(1)

  defp leg, do: map(integer(0..400), &{:leg, &1})

  defp stops, do: map(list_of(integer(0..150), max_length: 1), fn services -> Enum.map(services, &{:stop, &1}) end)

  defp limits, do: member_of([{@limit, @unbounded}, {@unbounded, @limit}, {270, 360}, {360, 270}, {270, 270}])

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

  property "the fold equals the brute walk, under one limit or both" do
    check all(tokens <- route_tokens(), {drive, work} <- limits(), max_runs: 2_000) do
      assert Native.drive_clock_fold_nif(tokens, drive, work) ==
               Native.drive_clock_brute_nif(tokens, drive, work)
    end
  end

  property "a split merges back exactly when the second part holds no break" do
    check all(
            tokens <- route_tokens(),
            split <- integer(last_break(tokens)..length(tokens)),
            {drive, work} <- limits(),
            max_runs: 2_000
          ) do
      assert Native.drive_clock_fold_split_nif(tokens, split, drive, work) ==
               Native.drive_clock_brute_nif(tokens, drive, work)
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

  test "one break serves both clocks, so it falls where the first of them needs it" do
    # 60 driven and 330 worked before the leg: the work limit of 360 is reached
    # 30 into it, so the break falls there and leaves 210 + 90 = 300 of driving
    # after it, past the drive limit of 270.
    tokens = [{:leg, 60}, {:stop, 270}, :break, {:leg, 240}, {:leg, 90}]

    assert Native.drive_clock_fold_nif(tokens, 270, 360) == {{30, 1}, {0, 0}}

    # A second break on the leg comes 270 after the first, past its end.
    two_breaks = [{:leg, 60}, {:stop, 270}, :break, :break, {:leg, 240}, {:leg, 90}]
    assert Native.drive_clock_fold_nif(two_breaks, 270, 360) == {{0, 0}, {0, 0}}
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

defmodule ExVrp.LoadSegmentTest do
  use ExUnit.Case, async: true

  alias ExVrp.LoadSegment

  @moduletag :nif_required

  @int_max 9_223_372_036_854_775_807

  describe "attribute getters" do
    test "returns passed in values (1, 2, 3)" do
      ls = LoadSegment.new(1, 2, 3)
      assert LoadSegment.delivery(ls) == 1
      assert LoadSegment.pickup(ls) == 2
      assert LoadSegment.load(ls) == 3
    end

    test "returns passed in values (0, 0, 0)" do
      ls = LoadSegment.new(0, 0, 0)
      assert LoadSegment.delivery(ls) == 0
      assert LoadSegment.pickup(ls) == 0
      assert LoadSegment.load(ls) == 0
    end

    test "returns passed in values (INT_MAX, INT_MAX, INT_MAX)" do
      ls = LoadSegment.new(@int_max, @int_max, @int_max)
      assert LoadSegment.delivery(ls) == @int_max
      assert LoadSegment.pickup(ls) == @int_max
      assert LoadSegment.load(ls) == @int_max
    end
  end

  describe "merge/2" do
    test "merges two segments correctly (case 1)" do
      first = LoadSegment.new(5, 8, 8)
      second = LoadSegment.new(3, 9, 11)

      # Expected: delivery = 5+3, pickup = 8+9, load = max(8+3, 11+8)
      merged = LoadSegment.merge(first, second)
      assert LoadSegment.delivery(merged) == 8
      assert LoadSegment.pickup(merged) == 17
      assert LoadSegment.load(merged) == 19

      # excess_load tests
      assert LoadSegment.excess_load(merged, 0) == 19
      assert LoadSegment.excess_load(merged, 19) == 0
    end

    test "merges two segments correctly (case 2 - reversed order)" do
      first = LoadSegment.new(3, 9, 11)
      second = LoadSegment.new(5, 8, 8)

      # Expected: delivery = 3+5, pickup = 9+8, load = max(11+5, 8+9)
      merged = LoadSegment.merge(first, second)
      assert LoadSegment.delivery(merged) == 8
      assert LoadSegment.pickup(merged) == 17
      assert LoadSegment.load(merged) == 17

      # excess_load tests
      assert LoadSegment.excess_load(merged, 0) == 17
      assert LoadSegment.excess_load(merged, 17) == 0
    end
  end

  describe "excess_load with capacity" do
    test "correctly evaluates and merges excess load" do
      before = LoadSegment.new(5, 5, 5, 30)
      after_seg = LoadSegment.new(2, 2, 2, 5)
      merged = LoadSegment.merge(before, after_seg)

      # There's seven load on this segment, but 30 excess load from some part of
      # the route executed before the last return to the depot, and 5 excess load
      # from part of the route executed after the next return to the depot.
      assert LoadSegment.load(merged) == 7
      assert LoadSegment.excess_load(merged, 7) == 35
      assert LoadSegment.excess_load(merged, 0) == 42
    end
  end

  describe "finalise/2" do
    test "correctly tracks excess load with capacity 10" do
      segment = LoadSegment.new(5, 5, 5, 20)
      finalised = LoadSegment.finalise(segment, 10)

      # Finalised segments track cumulative excess load - the rest resets.
      assert LoadSegment.delivery(finalised) == 0
      assert LoadSegment.pickup(finalised) == 0
      assert LoadSegment.load(finalised) == 0
      assert LoadSegment.excess_load(finalised, 10) == 20
    end

    test "correctly tracks excess load with capacity 5" do
      segment = LoadSegment.new(5, 5, 5, 20)
      finalised = LoadSegment.finalise(segment, 5)

      assert LoadSegment.delivery(finalised) == 0
      assert LoadSegment.pickup(finalised) == 0
      assert LoadSegment.load(finalised) == 0
      assert LoadSegment.excess_load(finalised, 5) == 20
    end

    test "correctly tracks excess load with capacity 0" do
      segment = LoadSegment.new(5, 5, 5, 20)
      finalised = LoadSegment.finalise(segment, 0)

      assert LoadSegment.delivery(finalised) == 0
      assert LoadSegment.pickup(finalised) == 0
      assert LoadSegment.load(finalised) == 0
      assert LoadSegment.excess_load(finalised, 0) == 25
    end
  end
end

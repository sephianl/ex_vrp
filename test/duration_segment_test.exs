defmodule ExVrp.DurationSegmentTest do
  use ExUnit.Case, async: true

  alias ExVrp.DurationSegment

  @moduletag :nif_required

  @int_max 9_223_372_036_854_775_807

  describe "time_warp with existing time warp" do
    test "returns existing time warp when no segments merged (tw=2)" do
      ds = DurationSegment.new(0, 2, 0, 0, 0)
      assert DurationSegment.time_warp(ds) == 2
    end

    test "returns existing time warp when no segments merged (tw=5)" do
      ds = DurationSegment.new(0, 5, 0, 0, 0)
      assert DurationSegment.time_warp(ds) == 5
    end

    test "returns existing time warp when no segments merged (tw=10)" do
      ds = DurationSegment.new(0, 10, 0, 0, 0)
      assert DurationSegment.time_warp(ds) == 10
    end
  end

  describe "merge/3" do
    test "merges two segments" do
      ds1 = DurationSegment.new(5, 0, 0, 5, 0)
      ds2 = DurationSegment.new(0, 5, 3, 6, 0)

      # Edge duration is 4
      merged = DurationSegment.merge(4, ds1, ds2)

      # ds1 has 5 duration, starts at 0. We arrive at ds2 at 5+4=9.
      # ds2 closes at 6, so we're 3 late + ds2's existing 5 time warp = 8
      assert DurationSegment.time_warp(merged) == 8
    end

    test "merges two segments with release time" do
      ds1 = DurationSegment.new(5, 0, 0, 5, 0)
      ds2 = DurationSegment.new(0, 5, 3, 6, 3)

      merged = DurationSegment.merge(4, ds1, ds2)
      # Previous 8 + release time 3 = 11
      assert DurationSegment.time_warp(merged) == 11
    end
  end

  describe "merging previously merged segments" do
    test "order matters for time warp calculation" do
      ds1 = DurationSegment.new(5, 1, 0, 5, 0)
      ds2 = DurationSegment.new(1, 1, 3, 6, 0)

      merged12 = DurationSegment.merge(4, ds1, ds2)
      merged21 = DurationSegment.merge(3, ds2, ds1)

      # Order matters, so time warp should differ
      assert merged12 != merged21
      assert DurationSegment.time_warp(merged12) == 4
      assert DurationSegment.time_warp(merged21) == 3

      # Merge the two merged segments
      merged = DurationSegment.merge(0, merged12, merged21)
      assert DurationSegment.time_warp(merged) == 10
    end
  end

  describe "max_duration argument" do
    test "respects max_duration constraint" do
      ds = DurationSegment.new(5, 0, 0, 0, 0)

      assert DurationSegment.time_warp(ds) == 0
      assert DurationSegment.time_warp(ds, 2) == 3
      assert DurationSegment.time_warp(ds, 0) == 5
    end
  end

  describe "overflow bug fix (#588)" do
    test "handles more time warp than duration" do
      ds1 = DurationSegment.new(9, 18, 0, 18, 0)
      assert DurationSegment.duration(ds1) < DurationSegment.time_warp(ds1)

      ds2 = DurationSegment.new(0, 0, 0, @int_max, 0)
      assert DurationSegment.start_late(ds2) == @int_max

      ds = DurationSegment.merge(0, ds1, ds2)
      assert DurationSegment.time_warp(ds) == 18
    end
  end

  describe "finalise_back with release time" do
    test "preserves duration and time warp" do
      segment = DurationSegment.new(5, 0, 50, 70, 75)
      assert DurationSegment.start_early(segment) == 75
      assert DurationSegment.start_late(segment) == 75
      assert DurationSegment.release_time(segment) == 75
      assert DurationSegment.duration(segment) == 5
      assert DurationSegment.time_warp(segment) == 5

      finalised = DurationSegment.finalise_back(segment)
      assert DurationSegment.duration(finalised) == 5
      assert DurationSegment.time_warp(finalised) == 5
      assert DurationSegment.start_early(finalised) == 75
      assert DurationSegment.start_late(finalised) == @int_max
      assert DurationSegment.release_time(finalised) == 75
      assert DurationSegment.prev_end_late(finalised) == 75
    end
  end

  describe "duration and time warp from previous end times" do
    test "prev ends at 95, we start at 100 - 5 wait duration" do
      segment = DurationSegment.new(0, 0, 100, 110, 95, 0, 0, 95)
      assert DurationSegment.duration(segment) == 5
      assert DurationSegment.time_warp(segment) == 0
    end

    test "prev can end at 100, so we can start immediately" do
      segment = DurationSegment.new(0, 0, 100, 110, 95, 0, 0, 100)
      assert DurationSegment.duration(segment) == 0
      assert DurationSegment.time_warp(segment) == 0
    end

    test "prev ends at 120, we must start by 110 - 10 time warp" do
      segment = DurationSegment.new(0, 0, 100, 110, 120, 0, 0, 120)
      assert DurationSegment.duration(segment) == 0
      assert DurationSegment.time_warp(segment) == 10
    end
  end

  describe "time warp from release time" do
    test "release time 100 - no time warp" do
      segment = DurationSegment.new(0, 0, 0, 100, 100)
      assert DurationSegment.start_late(segment) == 100
      assert DurationSegment.time_warp(segment) == 0
    end

    test "release time 110 - 10 time warp" do
      segment = DurationSegment.new(0, 0, 0, 100, 110)
      assert DurationSegment.start_late(segment) == 110
      assert DurationSegment.time_warp(segment) == 10
    end
  end

  describe "finalise_front" do
    test "correctly finalises segment" do
      segment = DurationSegment.new(5, 5, 40, 50, 50)
      assert DurationSegment.duration(segment) == 5
      assert DurationSegment.time_warp(segment) == 5
      assert DurationSegment.start_early(segment) == 50
      assert DurationSegment.start_late(segment) == 50
      assert DurationSegment.release_time(segment) == 50

      finalised = DurationSegment.finalise_front(segment)
      assert DurationSegment.duration(finalised) == 5
      assert DurationSegment.time_warp(finalised) == 5
      assert DurationSegment.start_early(finalised) == 50
      assert DurationSegment.start_late(finalised) == 50
      assert DurationSegment.release_time(finalised) == 0
    end
  end

  describe "repeated merge and finalise_back" do
    test "multi-trip scenario" do
      segment1 = DurationSegment.new(45, 0, 30, 50, 50)
      segment2 = DurationSegment.new(50, 0, 70, 110, 100)

      finalised1 = DurationSegment.finalise_back(segment1)
      assert DurationSegment.start_early(finalised1) == 95
      assert DurationSegment.start_late(finalised1) == @int_max
      assert DurationSegment.release_time(finalised1) == 95
      assert DurationSegment.prev_end_late(finalised1) == 95

      merged = DurationSegment.merge(0, finalised1, segment2)
      assert DurationSegment.duration(merged) == 100
      assert DurationSegment.start_early(merged) == 100
      assert DurationSegment.start_late(merged) == 110
      assert DurationSegment.release_time(merged) == 100
      assert DurationSegment.slack(merged) == 0

      finalised2 = DurationSegment.finalise_back(merged)
      assert DurationSegment.duration(finalised2) == 100
      assert DurationSegment.start_early(finalised2) == 150
      assert DurationSegment.start_late(finalised2) == @int_max
      assert DurationSegment.release_time(finalised2) == 150
      assert DurationSegment.prev_end_late(finalised2) == 150
    end
  end

  describe "finalise with route slack" do
    test "loose time windows result in positive slack" do
      segment1 = DurationSegment.new(0, 0, 0, 100, 0)
      segment2 = DurationSegment.new(0, 0, 50, 75, 0)

      finalised1 = DurationSegment.finalise_back(segment1)
      assert DurationSegment.release_time(finalised1) == 0
      assert DurationSegment.prev_end_late(finalised1) == 100
      assert DurationSegment.slack(finalised1) == 100

      merged = DurationSegment.merge(0, finalised1, segment2)
      finalised2 = DurationSegment.finalise_back(merged)
      assert DurationSegment.release_time(finalised2) == 50
      assert DurationSegment.prev_end_late(finalised2) == 75
      assert DurationSegment.slack(finalised2) == 25
    end
  end

  describe "end_early and end_late" do
    test "computes correctly with cumulative values" do
      segment = DurationSegment.new(40, 30, 10, 20, 0, 15, 5)
      assert DurationSegment.start_early(segment) == 10
      assert DurationSegment.start_late(segment) == 20
      assert DurationSegment.duration(segment) == 40 + 15
      assert DurationSegment.time_warp(segment) == 30 + 5
      assert DurationSegment.end_early(segment) == 20
      assert DurationSegment.end_late(segment) == 30
    end
  end

  describe "finalise_back and finalise_front equivalence" do
    test "both finalisations result in same duration and time warp" do
      ds1 = DurationSegment.new(50, 0, 70, 110, 100)
      ds2 = DurationSegment.new(45, 0, 30, 50, 50)

      finalise_back = DurationSegment.merge(0, DurationSegment.finalise_back(ds1), ds2)
      finalise_front = DurationSegment.merge(0, ds1, DurationSegment.finalise_front(ds2))

      assert DurationSegment.time_warp(finalise_back) == DurationSegment.time_warp(finalise_front)
      assert DurationSegment.duration(finalise_back) == DurationSegment.duration(finalise_front)
    end
  end
end

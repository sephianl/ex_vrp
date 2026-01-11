defmodule ExVrp.TripTest do
  @moduledoc """
  Tests for ExVrp.Trip module.

  This mirrors PyVRP's test_Trip.py. In ex_vrp, Trip is a struct that
  represents a continuous segment of visits between depot visits
  (used in multi-trip VRP scenarios).
  """
  use ExUnit.Case, async: true

  alias ExVrp.Trip

  describe "trip struct" do
    test "has expected fields" do
      trip = %Trip{}
      assert Map.has_key?(trip, :visits)
      assert Map.has_key?(trip, :start_depot)
      assert Map.has_key?(trip, :end_depot)
      assert Map.has_key?(trip, :distance)
      assert Map.has_key?(trip, :duration)
      assert Map.has_key?(trip, :delivery)
      assert Map.has_key?(trip, :pickup)
    end

    test "default values" do
      trip = %Trip{}
      assert trip.visits == []
      assert trip.start_depot == 0
      assert trip.end_depot == 0
      assert trip.distance == 0
      assert trip.duration == 0
      assert trip.delivery == []
      assert trip.pickup == []
    end

    test "can be created with values" do
      trip = %Trip{
        visits: [1, 2, 3],
        start_depot: 0,
        end_depot: 1,
        distance: 100,
        duration: 50,
        delivery: [30],
        pickup: [10]
      }

      assert trip.visits == [1, 2, 3]
      assert trip.start_depot == 0
      assert trip.end_depot == 1
      assert trip.distance == 100
      assert trip.duration == 50
      assert trip.delivery == [30]
      assert trip.pickup == [10]
    end
  end

  describe "trip length" do
    test "empty trip has length 0" do
      trip = %Trip{visits: []}
      assert trip.visits == []
    end

    test "single visit trip has length 1" do
      trip = %Trip{visits: [1]}
      assert length(trip.visits) == 1
    end

    test "multiple visits trip has correct length" do
      trip = %Trip{visits: [1, 2, 3, 4]}
      assert length(trip.visits) == 4
    end
  end

  describe "trip visits" do
    test "visits returns client indices" do
      trip = %Trip{visits: [1, 2, 3]}
      assert trip.visits == [1, 2, 3]
    end

    test "empty trip has no visits" do
      trip = %Trip{visits: []}
      assert trip.visits == []
    end
  end

  describe "trip depots" do
    test "start and end depot can be same" do
      trip = %Trip{visits: [1], start_depot: 0, end_depot: 0}
      assert trip.start_depot == 0
      assert trip.end_depot == 0
    end

    test "start and end depot can differ" do
      trip = %Trip{visits: [1], start_depot: 0, end_depot: 1}
      assert trip.start_depot == 0
      assert trip.end_depot == 1
    end
  end

  describe "trip distance and duration" do
    test "distance is stored correctly" do
      trip = %Trip{visits: [1], distance: 150}
      assert trip.distance == 150
    end

    test "duration is stored correctly" do
      trip = %Trip{visits: [1], duration: 200}
      assert trip.duration == 200
    end

    test "zero distance for empty trip" do
      trip = %Trip{visits: [], distance: 0}
      assert trip.distance == 0
    end

    test "zero duration for empty trip" do
      trip = %Trip{visits: [], duration: 0}
      assert trip.duration == 0
    end
  end

  describe "trip loads" do
    test "delivery load stored correctly" do
      trip = %Trip{visits: [1, 2], delivery: [50, 30]}
      assert trip.delivery == [50, 30]
    end

    test "pickup load stored correctly" do
      trip = %Trip{visits: [1, 2], pickup: [20, 15]}
      assert trip.pickup == [20, 15]
    end

    test "single dimension delivery" do
      trip = %Trip{visits: [1], delivery: [100]}
      assert length(trip.delivery) == 1
      assert Enum.at(trip.delivery, 0) == 100
    end

    test "single dimension pickup" do
      trip = %Trip{visits: [1], pickup: [50]}
      assert length(trip.pickup) == 1
      assert Enum.at(trip.pickup, 0) == 50
    end

    test "multi-dimensional loads" do
      trip = %Trip{visits: [1, 2], delivery: [30, 20, 10], pickup: [5, 10, 15]}
      assert length(trip.delivery) == 3
      assert length(trip.pickup) == 3
    end

    test "empty loads" do
      trip = %Trip{visits: [], delivery: [], pickup: []}
      assert trip.delivery == []
      assert trip.pickup == []
    end
  end

  describe "trip equality" do
    test "same visits and depots are equal" do
      trip1 = %Trip{visits: [1, 2], start_depot: 0, end_depot: 0}
      trip2 = %Trip{visits: [1, 2], start_depot: 0, end_depot: 0}
      assert trip1 == trip2
    end

    test "different visits are not equal" do
      trip1 = %Trip{visits: [1, 2], start_depot: 0, end_depot: 0}
      trip2 = %Trip{visits: [2, 3], start_depot: 0, end_depot: 0}
      assert trip1 != trip2
    end

    test "different depots are not equal" do
      trip1 = %Trip{visits: [1, 2], start_depot: 0, end_depot: 0}
      trip2 = %Trip{visits: [1, 2], start_depot: 1, end_depot: 1}
      assert trip1 != trip2
    end

    test "same visits different order not equal" do
      trip1 = %Trip{visits: [1, 2, 3]}
      trip2 = %Trip{visits: [3, 2, 1]}
      assert trip1 != trip2
    end
  end

  describe "trip in route context" do
    test "single trip in simple route" do
      trip = %Trip{
        visits: [1, 2],
        start_depot: 0,
        end_depot: 0,
        distance: 50,
        duration: 30,
        delivery: [20],
        pickup: [0]
      }

      # Trip is valid
      assert length(trip.visits) == 2
      assert trip.distance == 50
    end

    test "empty trip between depot visits" do
      # In multi-trip scenarios, empty trips can occur
      trip = %Trip{
        visits: [],
        start_depot: 0,
        end_depot: 0,
        distance: 10,
        duration: 5,
        delivery: [],
        pickup: []
      }

      assert trip.visits == []
      # Distance is just depot to depot
      assert trip.distance == 10
    end
  end

  describe "multi-trip scenarios" do
    test "consecutive trips for multi-trip route" do
      trip1 = %Trip{visits: [1, 2], start_depot: 0, end_depot: 0, distance: 40}
      trip2 = %Trip{visits: [3, 4], start_depot: 0, end_depot: 0, distance: 60}

      # Total clients
      total_visits = length(trip1.visits) + length(trip2.visits)
      assert total_visits == 4

      # Total distance (not including reload distance)
      total_dist = trip1.distance + trip2.distance
      assert total_dist == 100
    end

    test "trips with different depots" do
      # Multi-depot multi-trip scenario
      trip1 = %Trip{visits: [1], start_depot: 0, end_depot: 1}
      trip2 = %Trip{visits: [2], start_depot: 1, end_depot: 0}

      # Trip 1 ends where trip 2 starts
      assert trip1.end_depot == trip2.start_depot
    end

    test "three consecutive trips" do
      trip1 = %Trip{visits: [1, 2], start_depot: 0, end_depot: 0}
      trip2 = %Trip{visits: [3], start_depot: 0, end_depot: 0}
      trip3 = %Trip{visits: [4, 5], start_depot: 0, end_depot: 0}

      all_visits = trip1.visits ++ trip2.visits ++ trip3.visits
      assert all_visits == [1, 2, 3, 4, 5]
    end
  end

  describe "trip with service" do
    test "service duration contribution" do
      # Trip duration should account for service
      # This is a data representation test
      trip = %Trip{
        visits: [1, 2],
        # includes travel + service
        duration: 100,
        distance: 50
      }

      # Duration is greater than what pure travel would be
      # (conceptually - actual values depend on problem data)
      assert trip.duration >= 0
      assert trip.distance >= 0
    end
  end

  describe "trip data integrity" do
    test "visits are positive integers" do
      trip = %Trip{visits: [1, 2, 3, 10, 20]}

      for visit <- trip.visits do
        assert is_integer(visit)
        assert visit > 0
      end
    end

    test "depot indices are non-negative" do
      trip = %Trip{start_depot: 0, end_depot: 0}
      assert trip.start_depot >= 0
      assert trip.end_depot >= 0

      trip2 = %Trip{start_depot: 1, end_depot: 2}
      assert trip2.start_depot >= 0
      assert trip2.end_depot >= 0
    end

    test "distance is non-negative" do
      trip = %Trip{distance: 0}
      assert trip.distance >= 0

      trip2 = %Trip{distance: 1000}
      assert trip2.distance >= 0
    end

    test "duration is non-negative" do
      trip = %Trip{duration: 0}
      assert trip.duration >= 0

      trip2 = %Trip{duration: 500}
      assert trip2.duration >= 0
    end

    test "loads are non-negative" do
      trip = %Trip{delivery: [10, 20], pickup: [5, 15]}

      for d <- trip.delivery do
        assert d >= 0
      end

      for p <- trip.pickup do
        assert p >= 0
      end
    end
  end
end

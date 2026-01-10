defmodule ExVrp.ClientTest do
  @moduledoc """
  Tests ported from PyVRP's test_ProblemData.py - Client tests
  """
  use ExUnit.Case, async: true

  alias ExVrp.Client

  describe "new/1" do
    test "creates client with required fields" do
      client = Client.new(x: 1, y: 2)

      assert client.x == 1
      assert client.y == 2
    end

    test "creates client with all fields" do
      # Ported from PyVRP test_client_constructor
      client =
        Client.new(
          x: 1,
          y: 1,
          delivery: [1],
          pickup: [1],
          service_duration: 1,
          tw_early: 0,
          tw_late: 1,
          release_time: 0,
          prize: 0,
          required: true,
          group: nil,
          name: "test name"
        )

      assert client.x == 1
      assert client.y == 1
      assert client.delivery == [1]
      assert client.pickup == [1]
      assert client.service_duration == 1
      assert client.tw_early == 0
      assert client.tw_late == 1
      assert client.release_time == 0
      assert client.prize == 0
      assert client.required == true
      assert client.group == nil
      assert client.name == "test name"
    end

    test "has sensible defaults" do
      client = Client.new(x: 0, y: 0)

      assert client.delivery == [0]
      assert client.pickup == [0]
      assert client.service_duration == 0
      assert client.tw_early == 0
      assert client.tw_late == :infinity
      assert client.release_time == 0
      assert client.prize == 0
      assert client.required == true
      assert client.group == nil
      assert client.name == ""
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, fn ->
        Client.new(x: 1)
      end

      assert_raise ArgumentError, fn ->
        Client.new(y: 1)
      end
    end

    test "supports multi-dimensional capacity" do
      # Ported from PyVRP test - clients can have multiple capacity dimensions
      client = Client.new(x: 0, y: 0, delivery: [1, 2], pickup: [3, 4])

      assert client.delivery == [1, 2]
      assert client.pickup == [3, 4]
    end
  end
end

defmodule ExVrp.ClientGroupTest do
  use ExUnit.Case, async: true

  alias ExVrp.ClientGroup

  describe "new/1" do
    test "creates group with default options" do
      group = ClientGroup.new()

      assert group.clients == []
      assert group.required == true
      assert group.mutually_exclusive == false
      assert group.name == ""
    end

    test "creates non-required group with mutually_exclusive true by default" do
      group = ClientGroup.new(required: false)

      assert group.required == false
      assert group.mutually_exclusive == true
    end

    test "creates group with custom name" do
      group = ClientGroup.new(name: "priority_customers")

      assert group.name == "priority_customers"
    end

    test "allows overriding mutually_exclusive independently" do
      # Required group can still be mutually exclusive
      group = ClientGroup.new(required: true, mutually_exclusive: true)

      assert group.required == true
      assert group.mutually_exclusive == true
    end
  end

  describe "add_client/2" do
    test "adds client index to group" do
      group = ClientGroup.new()

      group = ClientGroup.add_client(group, 5)
      assert group.clients == [5]

      group = ClientGroup.add_client(group, 10)
      assert group.clients == [5, 10]
    end

    test "preserves other group properties" do
      group = ClientGroup.new(required: false, name: "test")

      group = ClientGroup.add_client(group, 1)

      assert group.required == false
      assert group.mutually_exclusive == true
      assert group.name == "test"
    end
  end

  describe "clear/1" do
    test "removes all clients from group" do
      group =
        ClientGroup.new()
        |> ClientGroup.add_client(1)
        |> ClientGroup.add_client(2)
        |> ClientGroup.add_client(3)

      assert group.clients == [1, 2, 3]

      cleared = ClientGroup.clear(group)
      assert cleared.clients == []
    end

    test "preserves other group properties after clear" do
      group =
        [required: false, name: "priority"]
        |> ClientGroup.new()
        |> ClientGroup.add_client(1)
        |> ClientGroup.clear()

      assert group.required == false
      assert group.mutually_exclusive == true
      assert group.name == "priority"
    end

    test "clearing empty group is a no-op" do
      group = ClientGroup.new()
      cleared = ClientGroup.clear(group)

      assert cleared.clients == []
    end
  end
end

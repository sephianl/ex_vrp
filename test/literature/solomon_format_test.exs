defmodule ExVrp.Literature.SolomonFormatTest do
  use ExUnit.Case, async: true

  alias ExVrp.Literature.SolomonFormat
  alias ExVrp.Read

  @moduletag :tmp_dir

  @solomon """
  C101

  VEHICLE
  NUMBER     CAPACITY
    25         200

  CUSTOMER
  CUST NO.  XCOORD.   YCOORD.    DEMAND   READY TIME  DUE DATE   SERVICE TIME

      0      40         50          0          0       1236          0
      1      45         68         10        912        967         90
      2      45         70         30        825        870         90
  """

  test "reads back through ExVrp.Read with the depot first and every client's data", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "C101.vrp")
    File.write!(path, SolomonFormat.to_vrplib(@solomon))
    model = Read.read(path)

    assert [_depot] = model.depots
    assert [%{num_available: 25, capacity: [200], tw_early: 0, tw_late: 1236}] = model.vehicle_types

    assert Enum.map(model.clients, &{&1.delivery, &1.tw_early, &1.tw_late, &1.service_duration}) == [
             {[10], 912, 967, 90},
             {[30], 825, 870, 90}
           ]

    assert model.distance_matrices |> hd() |> Enum.at(1) |> Enum.at(2) == 2
  end
end

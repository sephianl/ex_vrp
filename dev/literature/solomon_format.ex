defmodule ExVrp.Literature.SolomonFormat do
  @moduledoc """
  Converts a VRPTW instance in Solomon's text format (Solomon and Homberger–Gehring, as
  CVRPLib ships them) to the VRPLIB dialect `ExVrp.Read` parses. Customer 0 is the depot
  and becomes node 1, so location indices, and with them the clients in the `.sol` files,
  stay the same.
  """

  @spec to_vrplib(String.t()) :: String.t()
  def to_vrplib(text) do
    [name | lines] = text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    {num_vehicles, capacity} = vehicle_fleet(lines)
    customers = customer_rows(lines)

    Enum.join(
      [
        "NAME : #{name}",
        "TYPE : VRPTW",
        "DIMENSION : #{length(customers)}",
        "VEHICLES : #{num_vehicles}",
        "CAPACITY : #{capacity}",
        "EDGE_WEIGHT_TYPE : EUC_2D",
        section("NODE_COORD_SECTION", customers, fn c -> [c.x, c.y] end),
        section("DEMAND_SECTION", customers, fn c -> [c.demand] end),
        section("SERVICE_TIME_SECTION", customers, fn c -> [c.service] end),
        section("TIME_WINDOW_SECTION", customers, fn c -> [c.ready, c.due] end),
        "DEPOT_SECTION",
        "1",
        "-1",
        "EOF",
        ""
      ],
      "\n"
    )
  end

  defp vehicle_fleet(lines) do
    [vehicle_values | _rest] = lines |> Enum.drop_while(&(not String.starts_with?(&1, "NUMBER"))) |> Enum.drop(1)
    [num_vehicles, capacity] = String.split(vehicle_values)
    {num_vehicles, capacity}
  end

  defp customer_rows(lines) do
    lines
    |> Enum.drop_while(&(not String.starts_with?(&1, "CUST NO")))
    |> Enum.drop(1)
    |> Enum.map(&customer_row/1)
  end

  defp customer_row(line) do
    [_id, x, y, demand, ready, due, service] = String.split(line)
    %{x: x, y: y, demand: demand, ready: ready, due: due, service: service}
  end

  defp section(header, customers, values) do
    rows =
      customers
      |> Enum.with_index(1)
      |> Enum.map(fn {customer, node} -> Enum.join([node | values.(customer)], " ") end)

    Enum.join([header | rows], "\n")
  end
end

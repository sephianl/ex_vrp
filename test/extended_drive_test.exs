defmodule ExVrp.ExtendedDriveTest do
  @moduledoc """
  Tests for a vehicle type's `:extended_drive`: driving past its start stays feasible below
  `:max_drive` but costs per unit, as part of the route's duration cost.

  The solve model puts the depot at 0 and two clients at 40 and -40 on a line, so serving one
  drives 80 and serving both drives 160. Client 1 is required; client 2 is optional, so its
  prize decides whether it is worth driving past the start at 100.
  """
  use ExUnit.Case, async: true

  alias ExVrp.ExtendedDrive
  alias ExVrp.Model
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  defp line_model(prize, vehicle_opts, client2_opts \\ []) do
    Model.new()
    |> Model.add_depot([])
    |> Model.add_client(delivery: [1])
    |> Model.add_client(Keyword.merge([delivery: [1], required: false, prize: prize], client2_opts))
    |> Model.add_vehicle_type(Keyword.merge([num_available: 1, capacity: [10]], vehicle_opts))
    |> Model.set_euclidean_matrices([{0, 0}, {40, 0}, {-40, 0}])
  end

  defp best(model) do
    {:ok, result} = Solver.solve(model, stop: StoppingCriteria.max_iterations(200))
    result.best
  end

  defp best(prize, vehicle_opts), do: best(line_model(prize, vehicle_opts))

  defp priced(start, unit_cost \\ 10),
    do: [max_drive: 200, extended_drive: ExtendedDrive.new(start: start, unit_cost: unit_cost)]

  describe "the solution's cost" do
    test "travel past the start is priced on top of the duration cost" do
      [route] = Solution.routes(best(1_000_000, priced(100)))

      assert Route.travel_duration(route) == 160
      assert Route.duration_cost(route) == 60 * 10
      assert Route.drive_excess(route) == 0
    end

    test "travel up to the start costs nothing" do
      [route] = Solution.routes(best(1_000_000, priced(160)))

      assert Route.travel_duration(route) == 160
      assert Route.duration_cost(route) == 0
    end

    test "a zero price prices nothing" do
      [route] = Solution.routes(best(1_000_000, priced(100, 0)))

      assert Route.duration_cost(route) == 0
    end

    test "travel past max_drive is still infeasible, and priced up to it as well" do
      solution = best(line_model(0, Keyword.put(priced(100), :max_drive, 150), required: true))
      [route] = Solution.routes(solution)

      assert Route.travel_duration(route) == 160
      assert Route.drive_excess(route) == 10
      assert Route.duration_cost(route) == 60 * 10
      refute Solution.feasible?(solution)
    end
  end

  describe "what the solver buys" do
    # Serving client 2 adds 80 distance and 60 extended driving: 80 + 600 at these prices.
    test "an order worth more than the extended driving is served" do
      solution = best(1_000, priced(100))

      assert Solution.num_clients(solution) == 2
      assert Solution.feasible?(solution)
    end

    test "an order worth less than the extended driving is left unplanned" do
      assert Solution.num_clients(best(500, priced(100))) == 1
    end

    test "without the price the same order is served" do
      assert Solution.num_clients(best(500, max_drive: 200)) == 2
    end
  end

  describe "the price in a move's delta" do
    alias ExVrp.Native

    # Clients on a line: 1 at 100, 2 at -100, 3 at 101. Moving 1 from [1, 2] next to 3 saves
    # 200 distance, and takes the priced route's drive from 400 to 200, under its start at 300.
    defp relocate_delta(priced_opts) do
      xs = [0, 100, -100, 101]
      matrix = for i <- xs, do: for(j <- xs, do: abs(i - j))

      model =
        Model.new()
        |> Model.add_depot(tw_late: 100_000)
        |> Model.add_client(delivery: [1], tw_late: 100_000)
        |> Model.add_client(delivery: [1], tw_late: 100_000)
        |> Model.add_client(delivery: [1], tw_late: 100_000)
        |> Model.add_vehicle_type([num_available: 1, capacity: [10], unit_distance_cost: 1] ++ priced_opts)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_distance_cost: 1)
        |> Model.set_distance_matrices([matrix])
        |> Model.set_duration_matrices([matrix])

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, cost_evaluator} = Native.create_cost_evaluator(load_penalties: [20.0], tw_penalty: 6.0, dist_penalty: 0.0)

      from = Native.make_search_route_nif(problem_data, [1, 2], 0, 0)
      to = Native.make_search_route_nif(problem_data, [3], 1, 1)

      client1 = Native.search_route_get_node_nif(from, 1)
      depot = Native.search_route_get_node_nif(to, 0)

      Native.exchange10_evaluate_nif(Native.create_exchange10_nif(problem_data), client1, depot, cost_evaluator)
    end

    test "moving a client off a route driving past its start saves the price too" do
      free = relocate_delta([])
      priced = relocate_delta(extended_drive: ExtendedDrive.new(start: 300, unit_cost: 3))

      assert free == -200
      assert priced == free - 100 * 3
    end
  end

  describe "validation" do
    test "a negative or non-integer start or price, or another struct, is rejected" do
      for extended_drive <- [
            ExtendedDrive.new(start: -1, unit_cost: 1),
            ExtendedDrive.new(start: 1, unit_cost: -1),
            ExtendedDrive.new(start: :infinity, unit_cost: 1),
            %{start: 1, unit_cost: 1}
          ] do
        assert {:error, [message]} = Model.validate(line_model(0, extended_drive: extended_drive))
        assert message =~ "extended_drive"
      end
    end
  end
end

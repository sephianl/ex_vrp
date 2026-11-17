defmodule ExVrp.ExtendedDriveTest do
  @moduledoc """
  Tests for a vehicle type's `:extended_drive`: driving past its start stays feasible below
  `:max_drive` but costs per unit, as part of the route's duration cost.

  The solve model puts the depot at 0 and two clients at 40 and -40 on a line, so serving one
  drives 80 and serving both drives 160. Client 1 is required; client 2 is optional, so its
  prize decides whether it is worth driving past the start at 100. At a unit cost of 10,
  serving client 2 adds 80 distance and 60 extended driving: 80 + 600.

  The move model puts clients 1 at 100, 2 at -100 and 3 at 101. Relocating client 1 from the
  priced route [1, 2] next to client 3 on the free route saves 200 distance, and takes the
  priced route's drive from 400 to 200, under its start at 300.
  """
  use ExUnit.Case, async: true

  alias ExVrp.ExtendedDrive
  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria

  @moduletag :nif_required

  @line_max_drive 200

  defp line_model(client2_prize, max_drive, extended_drive, client2_required? \\ false) do
    Model.new()
    |> Model.add_depot([])
    |> Model.add_client(delivery: [1])
    |> Model.add_client(delivery: [1], required: client2_required?, prize: client2_prize)
    |> Model.add_vehicle_type(
      num_available: 1,
      capacity: [10],
      max_drive: max_drive,
      extended_drive: extended_drive
    )
    |> Model.set_euclidean_matrices([{0, 0}, {40, 0}, {-40, 0}])
  end

  defp best(model) do
    {:ok, result} = Solver.solve(model, stop: StoppingCriteria.max_iterations(200))
    result.best
  end

  defp best_on_line(client2_prize, extended_drive), do: best(line_model(client2_prize, @line_max_drive, extended_drive))

  defp extended_from(start, unit_cost \\ 10), do: ExtendedDrive.new(start: start, unit_cost: unit_cost)

  defp relocate_client1_delta(priced_route_extended_drive) do
    xs = [0, 100, -100, 101]
    matrix = for i <- xs, do: for(j <- xs, do: abs(i - j))

    model =
      Model.new()
      |> Model.add_depot(tw_late: 100_000)
      |> Model.add_client(delivery: [1], tw_late: 100_000)
      |> Model.add_client(delivery: [1], tw_late: 100_000)
      |> Model.add_client(delivery: [1], tw_late: 100_000)
      |> Model.add_vehicle_type(
        num_available: 1,
        capacity: [10],
        unit_distance_cost: 1,
        extended_drive: priced_route_extended_drive
      )
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

  describe "the solution's cost" do
    test "travel past the start is priced on top of the duration cost" do
      [route] = Solution.routes(best_on_line(1_000_000, extended_from(100)))

      assert Route.travel_duration(route) == 160
      assert Route.duration_cost(route) == 60 * 10
      assert Route.drive_excess(route) == 0
    end

    test "travel up to the start costs nothing" do
      [route] = Solution.routes(best_on_line(1_000_000, extended_from(160)))

      assert Route.travel_duration(route) == 160
      assert Route.duration_cost(route) == 0
    end

    test "a zero price prices nothing" do
      [route] = Solution.routes(best_on_line(1_000_000, extended_from(100, 0)))

      assert Route.duration_cost(route) == 0
    end

    test "travel past max_drive is still infeasible, and priced past max_drive too" do
      solution = best(line_model(0, 150, extended_from(100), true))
      [route] = Solution.routes(solution)

      assert Route.travel_duration(route) == 160
      assert Route.drive_excess(route) == 10
      assert Route.duration_cost(route) == 60 * 10
      refute Solution.feasible?(solution)
    end
  end

  describe "what the solver buys" do
    test "an order worth more than its distance and extended driving is served" do
      solution = best_on_line(1_000, extended_from(100))

      assert Solution.num_clients(solution) == 2
      assert Solution.feasible?(solution)
    end

    test "an order worth less than the extended driving is left unplanned" do
      assert Solution.num_clients(best_on_line(500, extended_from(100))) == 1
    end

    test "without the price the same order is served" do
      assert Solution.num_clients(best_on_line(500, nil)) == 2
    end
  end

  describe "the price in a move's delta" do
    test "moving a client off a route driving past its start saves the price too" do
      free = relocate_client1_delta(nil)
      priced = relocate_client1_delta(extended_from(300, 3))

      assert free == -200
      assert priced == free - 100 * 3
    end
  end

  describe "validation" do
    test "a negative or non-integer start or price, or another struct, is rejected" do
      for extended_drive <- [
            extended_from(-1, 1),
            extended_from(1, -1),
            extended_from(:infinity, 1),
            %{start: 1, unit_cost: 1}
          ] do
        assert {:error, [message]} = Model.validate(line_model(0, @line_max_drive, extended_drive))
        assert message =~ "extended_drive"
      end
    end

    test "a start at or past max_drive is rejected" do
      for start <- [@line_max_drive, @line_max_drive + 1] do
        assert {:error, [message]} = Model.validate(line_model(0, @line_max_drive, extended_from(start)))
        assert message =~ "below max_drive"
      end
    end

    test "any start is accepted under an unbounded max_drive" do
      assert :ok = Model.validate(line_model(0, :infinity, extended_from(1_000_000)))
    end
  end
end

defmodule ExVrp.VehicleLockTest do
  @moduledoc """
  Behavioural tests for vehicle locks: a client locked to one vehicle type pays
  a price whenever another vehicle type serves it. Soft, like the penalty
  channel it rides on.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model

  # One depot, two clients, two single-vehicle types.
  defp base_model do
    Model.new()
    |> Model.add_depot(tw_late: 1000)
    |> Model.add_client(delivery: [1], tw_late: 1000, required: false, prize: 1000)
    |> Model.add_client(delivery: [1], tw_late: 1000, required: false, prize: 1000)
    |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_distance_cost: 1)
    |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_distance_cost: 1)
    |> Model.set_distance_matrices([[[0, 10, 10], [10, 0, 10], [10, 10, 0]]])
    |> Model.set_duration_matrices([[[0, 10, 10], [10, 0, 10], [10, 10, 0]]])
  end

  describe "validation" do
    test "a model with locks on clients validates" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 0, price: 500}])

      assert :ok == Model.validate(model)
    end

    test "a lock on a depot is rejected" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 0, vehicle_type: 0, price: 500}])

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &(&1 =~ "lock"))
    end

    test "a lock naming a vehicle type that does not exist is rejected" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 7, price: 500}])

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &(&1 =~ "vehicle type"))
    end

    test "two locks on one client are rejected" do
      locks = [%{location: 1, vehicle_type: 0, price: 500}, %{location: 1, vehicle_type: 1, price: 500}]

      assert {:error, errors} = Model.validate(Model.set_vehicle_locks(base_model(), locks))
      assert Enum.any?(errors, &(&1 =~ "more than one lock"))
    end

    test "a lock on a member of a mutually exclusive client group validates" do
      model = Model.add_depot(Model.new(), tw_late: 1000)
      {model, group} = Model.add_client_group(model, required: true, mutually_exclusive: true)

      model =
        model
        |> Model.add_client(delivery: [1], tw_late: 1000, required: false, group: group)
        |> Model.add_client(delivery: [1], tw_late: 1000, required: false, group: group)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10])
        |> Model.set_distance_matrices([[[0, 10, 10], [10, 0, 10], [10, 10, 0]]])
        |> Model.set_duration_matrices([[[0, 10, 10], [10, 0, 10], [10, 10, 0]]])
        |> Model.set_vehicle_locks([%{location: 1, vehicle_type: 0, price: 500}])

      assert :ok == Model.validate(model)
    end

    test "a negative price is rejected" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 0, price: -1}])

      assert {:error, _errors} = Model.validate(model)
    end

    test "a negative vehicle type is rejected" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: -1, price: 500}])

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &(&1 =~ "vehicle_type"))
    end

    test "a float location is rejected" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1.0, vehicle_type: 0, price: 500}])

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &(&1 =~ "location"))
    end

    test "a float vehicle type is rejected" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 0.0, price: 500}])

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &(&1 =~ "vehicle_type"))
    end

    test "a lock map missing a key is rejected instead of raising" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 0}])

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &(&1 =~ "vehicle lock"))
    end

    test "a non-integer location alongside other bad fields is rejected instead of raising" do
      model =
        Model.set_vehicle_locks(base_model(), [
          %{location: {1}, vehicle_type: 99, price: -1},
          %{location: {1}, vehicle_type: 0, price: 500}
        ])

      assert {:error, errors} = Model.validate(model)
      assert Enum.any?(errors, &(&1 =~ "more than one lock"))
    end
  end

  describe "solution cost" do
    alias ExVrp.Solution
    alias ExVrp.Solver

    defp solve(model, initial_routes \\ nil) do
      Solver.solve(model,
        stop: ExVrp.StoppingCriteria.max_iterations(200),
        initial_routes: initial_routes
      )
    end

    test "a client served by its locked vehicle type pays nothing" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 0, price: 500}])

      {:ok, result} = solve(model, [[1, 2], []])

      assert Solution.lock_cost(result.best) == 0
    end

    test "a lock price is part of the solution's penalty cost" do
      locked = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 1, price: 5}])

      {:ok, result} = Solver.solve(locked, stop: ExVrp.StoppingCriteria.max_iterations(0), initial_routes: [[1, 2], []])

      assert Solution.lock_cost(result.best) == 5
      assert Solution.penalty_cost(result.best) == 5
    end

    test "a model without locks reports no lock cost" do
      {:ok, result} = solve(base_model())

      assert Solution.lock_cost(result.best) == 0
    end
  end

  describe "locks under local search" do
    alias ExVrp.Solution
    alias ExVrp.Solver

    # A line of locations, one depot at 0, two identical vehicle types. Every odd client is
    # locked to vehicle type 1, every even one to vehicle type 0. Without locks the solver is
    # free to split clients however routing cost prefers; a high enough price forces it to
    # split by lock instead.
    defp line_model(n, price) do
      locations = 0..n

      matrix = for i <- locations, do: for(j <- locations, do: abs(i - j) * 10)

      model =
        1..n
        |> Enum.reduce(Model.add_depot(Model.new(), tw_late: 100_000), fn _i, m ->
          Model.add_client(m, delivery: [1], tw_late: 100_000, required: true)
        end)
        |> Model.add_vehicle_type(num_available: 1, capacity: [n], unit_distance_cost: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [n], unit_distance_cost: 1)
        |> Model.set_distance_matrices([matrix])
        |> Model.set_duration_matrices([matrix])

      locks = for loc <- 1..n, do: %{location: loc, vehicle_type: rem(loc, 2), price: price}

      Model.set_vehicle_locks(model, locks)
    end

    test "a price above any routing gain puts every locked client on its vehicle type" do
      {:ok, result} = Solver.solve(line_model(12, 1_000_000), stop: ExVrp.StoppingCriteria.max_iterations(2_000))

      assert Solution.feasible?(result.best)
      assert Solution.lock_cost(result.best) == 0
    end

    test "a zero price leaves the solver free to ignore the locks" do
      {:ok, result} = Solver.solve(line_model(12, 0), stop: ExVrp.StoppingCriteria.max_iterations(2_000))

      assert Solution.lock_cost(result.best) == 0
      assert Solution.num_clients(result.best) == 12
    end

    test "a warm start with every client on the wrong vehicle type is moved back" do
      n = 12
      wrong = [Enum.filter(1..n, &(rem(&1, 2) == 1)), Enum.filter(1..n, &(rem(&1, 2) == 0))]

      {:ok, result} =
        Solver.solve(line_model(n, 1_000_000),
          stop: ExVrp.StoppingCriteria.max_iterations(2_000),
          initial_routes: wrong
        )

      assert Solution.lock_cost(result.best) == 0
    end

    test "a warm start's cost includes the lock price" do
      model = line_model(4, 1_000)

      {:ok, result} =
        Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(0), initial_routes: [[1, 3], [2, 4]])

      assert Solution.lock_cost(result.best) == 4 * 1_000
    end
  end

  describe "locks in a move's delta" do
    alias ExVrp.Native

    @price 50

    # Clients on a line: 1 at 100, 2 at -100, 3 at 101. Moving 1 away from 2 and next to 3 saves
    # 200 distance whichever route it leaves, so every move below is improving and its delta exact.
    # Both vehicle types share profile 0, so only the vehicle type tells the routes apart.
    defp relocate_delta(locks, from_visits, from_type, to_visits, to_type) do
      xs = [0, 100, -100, 101]
      matrix = for i <- xs, do: for(j <- xs, do: abs(i - j))

      model =
        Model.new()
        |> Model.add_depot(tw_late: 100_000)
        |> Model.add_client(delivery: [1], tw_late: 100_000)
        |> Model.add_client(delivery: [1], tw_late: 100_000)
        |> Model.add_client(delivery: [1], tw_late: 100_000)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_distance_cost: 1)
        |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_distance_cost: 1)
        |> Model.set_distance_matrices([matrix])
        |> Model.set_duration_matrices([matrix])
        |> Model.set_vehicle_locks(locks)

      {:ok, problem_data} = Model.to_problem_data(model)
      {:ok, cost_evaluator} = Native.create_cost_evaluator(load_penalties: [20.0], tw_penalty: 6.0, dist_penalty: 0.0)

      from = Native.make_search_route_nif(problem_data, from_visits, from_type, from_type)
      to = Native.make_search_route_nif(problem_data, to_visits, to_type, to_type)

      client1 = Native.search_route_get_node_nif(from, Enum.find_index(from_visits, &(&1 == 1)) + 1)
      depot = Native.search_route_get_node_nif(to, 0)

      Native.exchange10_evaluate_nif(Native.create_exchange10_nif(problem_data), client1, depot, cost_evaluator)
    end

    test "moving a client onto its locked vehicle type saves the price" do
      lock = [%{location: 1, vehicle_type: 1, price: @price}]

      free = relocate_delta([], [1, 2], 0, [3], 1)
      locked = relocate_delta(lock, [1, 2], 0, [3], 1)

      assert free == -200
      assert locked == free - @price
    end

    test "moving a client off its locked vehicle type costs the price" do
      lock = [%{location: 1, vehicle_type: 1, price: @price}]

      free = relocate_delta([], [1, 2], 1, [3], 0)
      locked = relocate_delta(lock, [1, 2], 1, [3], 0)

      assert free == -200
      assert locked == free + @price
    end
  end

  describe "locks on a mutually exclusive client group" do
    alias ExVrp.Solution
    alias ExVrp.Solver

    @group_price 1_000_000

    # Client 3 is required; clients 1 and 2 form a required mutually exclusive group, so exactly
    # one of them is visited. Both group members are locked to vehicle type 0.
    defp group_model do
      model = Model.add_depot(Model.new(), tw_late: 1000)
      {model, group} = Model.add_client_group(model, required: true, mutually_exclusive: true)

      model
      |> Model.add_client(delivery: [1], tw_late: 1000, required: false, group: group)
      |> Model.add_client(delivery: [1], tw_late: 1000, required: false, group: group)
      |> Model.add_client(delivery: [1], tw_late: 1000)
      |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_distance_cost: 1)
      |> Model.add_vehicle_type(num_available: 1, capacity: [10], unit_distance_cost: 1)
      |> Model.set_distance_matrices([[[0, 10, 10, 10], [10, 0, 10, 10], [10, 10, 0, 10], [10, 10, 10, 0]]])
      |> Model.set_duration_matrices([[[0, 10, 10, 10], [10, 0, 10, 10], [10, 10, 0, 10], [10, 10, 10, 0]]])
      |> Model.set_vehicle_locks([
        %{location: 1, vehicle_type: 0, price: @group_price},
        %{location: 2, vehicle_type: 0, price: @group_price}
      ])
    end

    test "the search puts the visited member on its locked vehicle type" do
      {:ok, result} =
        Solver.solve(group_model(), stop: ExVrp.StoppingCriteria.max_iterations(500), initial_routes: [[3], [1]])

      visited = result.best.routes |> List.flatten() |> Enum.filter(&(&1 in [1, 2]))

      assert length(visited) == 1
      assert Solution.lock_cost(result.best) == 0
    end

    test "only the visited member pays the lock" do
      {:ok, result} =
        Solver.solve(group_model(), stop: ExVrp.StoppingCriteria.max_iterations(0), initial_routes: [[3], [1]])

      assert Solution.lock_cost(result.best) == @group_price
    end
  end
end

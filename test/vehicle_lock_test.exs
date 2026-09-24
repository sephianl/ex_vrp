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

    test "a negative price is rejected" do
      model = Model.set_vehicle_locks(base_model(), [%{location: 1, vehicle_type: 0, price: -1}])

      assert {:error, _errors} = Model.validate(model)
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

    # A line of locations; vehicle type 0 starts at the far left, type 1 at the far right, both
    # at depot 0 for simplicity of the matrix but with a fixed cost difference per side. Every
    # odd client is locked to type 1, every even one to type 0. Without locks the solver
    # partitions by position; with a high price it must partition by lock instead.
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

    test "a vehicle type sharing the locked type's profile still pays the lock" do
      # Both vehicle types use profile 0, so SegmentBetween cannot short-circuit on profile alone.
      model = line_model(4, 1_000)

      {:ok, result} =
        Solver.solve(model, stop: ExVrp.StoppingCriteria.max_iterations(0), initial_routes: [[1, 3], [2, 4]])

      assert Solution.lock_cost(result.best) == 4 * 1_000
    end
  end
end

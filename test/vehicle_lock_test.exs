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
end

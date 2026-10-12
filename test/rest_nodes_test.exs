defmodule ExVrp.RestNodesTest do
  @moduledoc """
  A rest client is a break client that lasts its vehicle type's rest
  duration instead of its break duration. Client 3 is a break, client 4 a
  rest; both have matrix rows far away so that any lookup that reads them
  shows up as extra distance.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.Route
  alias ExVrp.Solution

  @moduletag :nif_required

  @break 3
  @rest 4
  @break_duration 45
  @rest_duration 660
  @points [{0, 0}, {10, 0}, {30, 0}, {1000, 0}, {2000, 0}]

  defp model(vehicle_opts) do
    vehicle =
      Keyword.merge(
        [
          num_available: 1,
          capacity: [0],
          unit_distance_cost: 1,
          unit_duration_cost: 1,
          rest_duration: @rest_duration
        ],
        vehicle_opts
      )

    Model.new()
    |> Model.add_depot([])
    |> Model.add_client([])
    |> Model.add_client([])
    |> Model.add_client(required: false, is_break: true)
    |> Model.add_client(required: false, is_break: true, is_rest: true)
    |> Model.add_vehicle_type(vehicle)
    |> Model.add_vehicle_type(Keyword.put(vehicle, :rest_duration, 2 * @rest_duration))
    |> Model.set_euclidean_matrices(@points)
  end

  defp route(visits, vehicle_opts \\ []) do
    {:ok, problem_data} = vehicle_opts |> model() |> Model.to_problem_data()
    {:ok, ref} = Native.create_solution_from_routes(problem_data, [visits])
    %Solution{solution_ref: ref, routes: [visits]} |> Solution.routes() |> hd()
  end

  describe "validation" do
    test "a rest client must be a break client" do
      model =
        Model.new()
        |> Model.add_depot([])
        |> Model.add_client(required: false, is_rest: true)
        |> Model.add_vehicle_type(num_available: 1, capacity: [0])
        |> Model.set_euclidean_matrices([{0, 0}, {1, 0}])

      assert_raise ArgumentError, ~r/rest clients must be break clients/, fn ->
        Model.to_problem_data(model)
      end
    end

    test "a negative rest duration is rejected" do
      assert_raise ArgumentError, ~r/rest_duration must be >= 0/, fn ->
        [rest_duration: -1] |> model() |> Model.to_problem_data()
      end
    end
  end
end

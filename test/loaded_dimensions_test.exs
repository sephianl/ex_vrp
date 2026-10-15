defmodule ExVrp.LoadedDimensionsTest do
  @moduledoc """
  Move evaluation prices only the load dimensions some client or vehicle type puts load in
  (`ProblemData::loadedDimensions`), since nothing can exceed capacity in the others. These
  pin down that skipping the unused ones never skips a used one: a dimension loaded only by
  pickups is still priced, and a dimension behind an unused one is priced with its own
  penalty.

  Every matrix is zero, so an insertion costs exactly its load penalties.
  """
  use ExUnit.Case, async: true

  alias ExVrp.Model
  alias ExVrp.Native

  @moduletag :nif_required

  @unused_delivered_picked_up_penalties [1_000.0, 10.0, 100.0]

  test "an insertion is priced in every loaded dimension, and only those" do
    {problem_data, cost_evaluator} = problem_with_an_unused_first_dimension()

    route = Native.make_search_route_nif(problem_data, [1], 0, 0)
    after_client_1 = Native.search_route_get_node_nif(route, 1)
    client_2 = Native.create_search_node_nif(problem_data, 2)

    delivered_excess = 4 + 4 - 5
    picked_up_excess = 4 + 4 - 5

    assert Native.insert_cost_nif(client_2, after_client_1, problem_data, cost_evaluator) ==
             10 * delivered_excess + 100 * picked_up_excess
  end

  defp problem_with_an_unused_first_dimension do
    zeros = List.duplicate([0, 0, 0], 3)

    {:ok, problem_data} =
      Model.new()
      |> Model.add_depot([])
      |> Model.add_client(delivery: [0, 4, 0], pickup: [0, 0, 4])
      |> Model.add_client(delivery: [0, 4, 0], pickup: [0, 0, 4])
      |> Model.add_vehicle_type(num_available: 1, capacity: [5, 5, 5])
      |> Model.set_distance_matrices([zeros])
      |> Model.set_duration_matrices([zeros])
      |> Model.to_problem_data()

    {:ok, cost_evaluator} =
      Native.create_cost_evaluator(
        load_penalties: @unused_delivered_picked_up_penalties,
        tw_penalty: 0.0,
        dist_penalty: 0.0
      )

    {problem_data, cost_evaluator}
  end
end

defmodule ExVrp.ProductionInsertionTest do
  @moduledoc """
  Zelo adding a batch of orders at 08:30 to a reefer depot's day under way: linked shipments with
  pickups loaded at the depot, trucks on the road that start when they drive on (`:start_late`),
  EU 561 breaks, and a warm start from the routes already planned. Each option the planner sees is
  one instance (moving planned orders freely, keeping them on their truck, sending an extra
  truck), captured on a day that left room for the batch and on one that did not
  (`priv/benchmark_data/insertion`).

  A short solve from the warm start has to stay feasible, visit every required client, take its
  breaks, and place at least as many clients as it does today. Where it places them all, a change
  that leaves one out is a regression the A/B benchmark would only show as a cost.
  """

  use ExUnit.Case, async: true

  alias ExVrp.ABBenchmark.Corpus
  alias ExVrp.ABBenchmark.Instance
  alias ExVrp.ABBenchmark.Loader
  alias ExVrp.Route
  alias ExVrp.Solution
  alias ExVrp.StoppingCriteria

  @moduletag timeout: 120_000

  @iterations 200

  @placed_at_least %{
    "ins_insertion_0830_free" => :all,
    "ins_insertion_0830_strict" => 81,
    "ins_insertion_0830_extra_truck" => :all,
    "ins_insertion_0830_tight_free" => 85,
    "ins_insertion_0830_tight_strict" => 85,
    "ins_insertion_0830_tight_extra_truck" => :all
  }

  for {id, placed} <- @placed_at_least do
    test "#{id}: feasible from its warm start, with breaks, placing #{placed} clients or more" do
      %Instance{model: model} = instance = Loader.load(entry(unquote(id)))
      best = solve(instance)

      assert Solution.feasible?(best)
      assert Solution.complete?(best)
      assert best |> Solution.routes() |> Enum.map(&length(Route.breaks(&1))) |> Enum.sum() > 0
      assert Solution.num_clients(best) >= at_least(unquote(placed), model)
    end
  end

  defp entry(id), do: Enum.find(Corpus.insertion_entries(), &(&1.id == id))

  defp solve(%Instance{model: model, penalty_params: penalty_params, initial_routes: initial_routes}) do
    {:ok, %{best: best}} =
      ExVrp.solve(model,
        stop: StoppingCriteria.max_iterations(@iterations),
        seed: 1,
        num_starts: 1,
        penalty_params: penalty_params,
        initial_routes: initial_routes
      )

    best
  end

  defp at_least(:all, model), do: length(model.clients)
  defp at_least(count, _model), do: count
end

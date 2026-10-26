defmodule ExVrp.Literature.BestKnownSolution do
  @moduledoc """
  A best-known solution in VRPLIB `.sol` format, and its cost evaluated on our model.

  Evaluating it ourselves puts every best-known cost in the units our solver reports,
  whatever scaling a source file uses. Clients are location indices with the depots first.
  A depot index inside a route is a reload there. Route `k` is vehicle `k - 1` of the
  instance, which `ExVrp.Read` names its vehicle type after.
  """

  alias ExVrp.Model
  alias ExVrp.Native
  alias ExVrp.PenaltyManager

  @type t :: %__MODULE__{
          routes: [{pos_integer(), [non_neg_integer()]}],
          stated_cost: float() | nil,
          optimal: boolean() | nil
        }

  defstruct routes: [], stated_cost: nil, optimal: nil

  @spec parse(String.t()) :: t()
  def parse(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce(%__MODULE__{}, &parse_line/2)
    |> Map.update!(:routes, &Enum.reverse/1)
  end

  defp parse_line("Route #" <> route, solution) do
    [number, visits] = String.split(route, ":", parts: 2)
    clients = visits |> String.split() |> Enum.map(&String.to_integer/1)
    %{solution | routes: [{String.to_integer(number), clients} | solution.routes]}
  end

  defp parse_line("Cost" <> cost, solution) do
    %{solution | stated_cost: cost |> String.trim_leading(":") |> String.trim() |> parse_number()}
  end

  defp parse_line("Optimal:" <> optimal, solution), do: %{solution | optimal: String.trim(optimal) == "True"}
  defp parse_line(_line, solution), do: solution

  defp parse_number(text) do
    {number, _rest} = Float.parse(text)
    number
  end

  @doc "The solution's cost on the model, or an error when it does not build a feasible solution there."
  @spec evaluate(t(), Model.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def evaluate(%__MODULE__{routes: routes}, %Model{} = model) do
    with {:ok, problem_data} <- Model.to_problem_data(model),
         {:ok, solution} <- Native.create_solution_from_routes_with_types(problem_data, typed_routes(routes, model)) do
      feasible_cost(solution, problem_data)
    end
  end

  defp feasible_cost(solution, problem_data) do
    {:ok, cost_evaluator} = problem_data |> PenaltyManager.init_from() |> PenaltyManager.max_cost_evaluator()
    solution |> Native.solution_is_feasible() |> cost_if_feasible(solution, cost_evaluator)
  end

  defp cost_if_feasible(true, solution, cost_evaluator), do: {:ok, Native.solution_cost(solution, cost_evaluator)}

  defp cost_if_feasible(false, _solution, _cost_evaluator),
    do: {:error, "best-known solution is infeasible on our model"}

  defp typed_routes(routes, model) do
    num_depots = length(model.depots)

    for {number, clients} <- routes, clients != [] do
      {vehicle_type_of(number - 1, model.vehicle_types), visits(clients, num_depots)}
    end
  end

  defp vehicle_type_of(_vehicle, [_only_type]), do: 0

  defp vehicle_type_of(vehicle, vehicle_types) do
    vehicle_name = Integer.to_string(vehicle)
    Enum.find_index(vehicle_types, fn vehicle_type -> vehicle_name in String.split(vehicle_type.name, ",") end)
  end

  defp visits(clients, num_depots) do
    clients
    |> Enum.chunk_while({nil, []}, &split_at_reload(&1, &2, num_depots), &emit_trip/1)
    |> trips_or_single_route()
  end

  defp split_at_reload(location, {reload_depot, clients}, num_depots) when location < num_depots do
    {:cont, %{reload_depot: reload_depot, clients: Enum.reverse(clients)}, {location, []}}
  end

  defp split_at_reload(client, {reload_depot, clients}, _num_depots), do: {:cont, {reload_depot, [client | clients]}}

  defp emit_trip({reload_depot, clients}),
    do: {:cont, %{reload_depot: reload_depot, clients: Enum.reverse(clients)}, nil}

  defp trips_or_single_route([%{reload_depot: nil, clients: clients}]), do: clients
  defp trips_or_single_route(trips), do: {:trips, trips}
end

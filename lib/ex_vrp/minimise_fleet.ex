defmodule ExVrp.MinimiseFleet do
  @moduledoc """
  Fleet minimisation for VRP instances.

  Attempts to reduce the number of vehicles needed to achieve a feasible
  solution to the given problem instance, subject to a stopping criterion.

  ## Warning

  This function is currently unable to solve instances with multiple
  vehicle types. Support for such a setting may be added in future versions.
  """

  alias ExVrp.Model
  alias ExVrp.Solver
  alias ExVrp.StoppingCriteria
  alias ExVrp.VehicleType

  @doc """
  Attempts to reduce the number of vehicles needed to achieve a feasible
  solution to the given problem instance.

  ## Parameters

    * `model` - The VRP model with a given vehicle composition
    * `stop` - Stopping criterion that determines how much effort to spend
    * `opts` - Options:
      * `:seed` - Seed value for RNG (default: 0)

  ## Returns

  Returns `{:ok, vehicle_type}` with the smallest fleet composition that
  admits a feasible solution, or `{:error, reason}` if validation fails.

  ## Raises

  Returns an error when the instance contains more than one vehicle type
  or when the instance contains optional clients.

  ## Examples

      {:ok, vehicle_type} = MinimiseFleet.minimise(model, StoppingCriteria.max_iterations(100))

  """
  @spec minimise(Model.t(), StoppingCriteria.t(), keyword()) ::
          {:ok, VehicleType.t()} | {:error, String.t()}
  def minimise(%Model{} = model, stop, opts \\ []) do
    seed = Keyword.get(opts, :seed, 0)

    with :ok <- validate_single_vehicle_type(model),
         :ok <- validate_no_optional_clients(model) do
      do_minimise(model, stop, seed)
    end
  end

  @doc "Same as `minimise/3` but raises on error."
  @spec minimise!(Model.t(), StoppingCriteria.t(), keyword()) :: VehicleType.t()
  def minimise!(%Model{} = model, stop, opts \\ []) do
    case minimise(model, stop, opts) do
      {:ok, vehicle_type} -> vehicle_type
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  # Private implementation

  defp validate_single_vehicle_type(%Model{vehicle_types: vehicle_types}) do
    if match?([_only], vehicle_types) do
      :ok
    else
      {:error, "Fleet minimisation does not understand multiple vehicle types."}
    end
  end

  defp validate_no_optional_clients(%Model{clients: clients}) do
    has_optional = Enum.any?(clients, fn client -> client.required == false end)

    if has_optional do
      {:error, "Fleet minimisation does not work with optional clients."}
    else
      :ok
    end
  end

  defp do_minimise(%Model{vehicle_types: [vehicle_type]} = model, stop, seed) do
    lower_bound = compute_lower_bound(model)
    minimise_loop(model, vehicle_type, lower_bound, stop, seed)
  end

  defp minimise_loop(model, feas_fleet, lower_bound, stop, seed) do
    if feas_fleet.num_available <= lower_bound do
      {:ok, feas_fleet}
    else
      # Reduce fleet by one vehicle
      reduced_fleet = %{feas_fleet | num_available: feas_fleet.num_available - 1}
      reduced_model = %{model | vehicle_types: [reduced_fleet]}

      combined_stop = StoppingCriteria.first_feasible_or(stop)

      reduced_model
      |> Solver.solve(stop: combined_stop, seed: seed)
      |> handle_minimise_result(reduced_model, reduced_fleet, feas_fleet, lower_bound, stop, seed)
    end
  end

  defp handle_minimise_result({:ok, %{best: %{is_feasible: true} = best}}, model, fleet, _feas_fleet, lb, stop, seed) do
    new_fleet = maybe_reduce_fleet(fleet, length(best.routes))
    minimise_loop(model, new_fleet, lb, stop, seed)
  end

  defp handle_minimise_result({:ok, _result}, _model, _fleet, feas_fleet, _lb, _stop, _seed) do
    {:ok, feas_fleet}
  end

  defp handle_minimise_result({:error, _reason}, _model, _fleet, feas_fleet, _lb, _stop, _seed) do
    {:ok, feas_fleet}
  end

  defp maybe_reduce_fleet(fleet, routes_used) when routes_used < fleet.num_available do
    %{fleet | num_available: routes_used}
  end

  defp maybe_reduce_fleet(fleet, _routes_used), do: fleet

  defp compute_lower_bound(%Model{clients: clients, vehicle_types: [vehicle_type]}) do
    capacities = if vehicle_type.capacity == [], do: [1], else: vehicle_type.capacity
    num_dims = length(capacities)
    max_trips = compute_max_trips(vehicle_type)
    zeros = List.duplicate(0, num_dims)

    {delivery_sums, pickup_sums} =
      Enum.reduce(clients, {zeros, zeros}, fn c, {d_acc, p_acc} ->
        {add_dimensions(d_acc, c.delivery), add_dimensions(p_acc, c.pickup)}
      end)

    [delivery_sums, pickup_sums, capacities]
    |> Enum.zip()
    |> Enum.reduce(1, fn {d_sum, p_sum, capacity}, best ->
      demand = max(d_sum, p_sum)
      effective_capacity = capacity * max_trips

      dim_bound = if effective_capacity > 0, do: ceil(demand / effective_capacity), else: 0
      max(dim_bound, best)
    end)
  end

  defp add_dimensions([], _vals), do: []
  defp add_dimensions(acc, []), do: acc
  defp add_dimensions([a | acc_rest], [v | vals_rest]), do: [a + v | add_dimensions(acc_rest, vals_rest)]

  defp compute_max_trips(%VehicleType{max_reloads: max_reloads}) do
    case max_reloads do
      # If infinite reloads but no reload_depots, treat as 1 trip
      :infinity -> 1
      n when is_integer(n) -> n + 1
    end
  end
end

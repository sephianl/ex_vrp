defmodule ExVrp.Model do
  @moduledoc """
  High-level builder for constructing VRP problems.

  The Model provides a fluent API for defining clients, depots,
  vehicle types, and routing constraints before solving.

  ## Example

      model =
        ExVrp.Model.new()
        |> ExVrp.Model.add_depot(x: 0, y: 0)
        |> ExVrp.Model.add_vehicle_type(num_available: 2, capacity: [100])
        |> ExVrp.Model.add_client(x: 1, y: 1, delivery: [10])
        |> ExVrp.Model.add_client(x: 2, y: 2, delivery: [20])
        |> ExVrp.Model.add_client(x: 3, y: 1, delivery: [15])

      {:ok, solution} = ExVrp.solve(model)

  """

  alias ExVrp.Client
  alias ExVrp.ClientGroup
  alias ExVrp.Depot
  alias ExVrp.VehicleType

  @type t :: %__MODULE__{
          clients: [Client.t()],
          depots: [Depot.t()],
          vehicle_types: [VehicleType.t()],
          client_groups: [ClientGroup.t()],
          distance_matrices: [[[non_neg_integer()]]],
          duration_matrices: [[[non_neg_integer()]]]
        }

  defstruct clients: [],
            depots: [],
            vehicle_types: [],
            client_groups: [],
            distance_matrices: [],
            duration_matrices: []

  @doc """
  Creates a new empty model.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Adds a client to the model.

  See `ExVrp.Client.new/1` for available options.

  ## Example

      model
      |> ExVrp.Model.add_client(x: 1, y: 2, delivery: [10])

  """
  @spec add_client(t(), keyword()) :: t()
  def add_client(%__MODULE__{clients: clients} = model, opts) do
    client = Client.new(opts)
    %{model | clients: clients ++ [client]}
  end

  @doc """
  Adds a depot to the model.

  See `ExVrp.Depot.new/1` for available options.

  ## Example

      model
      |> ExVrp.Model.add_depot(x: 0, y: 0)

  """
  @spec add_depot(t(), keyword()) :: t()
  def add_depot(%__MODULE__{depots: depots} = model, opts) do
    depot = Depot.new(opts)
    %{model | depots: depots ++ [depot]}
  end

  @doc """
  Adds a vehicle type to the model.

  See `ExVrp.VehicleType.new/1` for available options.

  ## Example

      model
      |> ExVrp.Model.add_vehicle_type(num_available: 3, capacity: [100])

  """
  @spec add_vehicle_type(t(), keyword()) :: t()
  def add_vehicle_type(%__MODULE__{vehicle_types: vehicle_types} = model, opts) do
    vehicle_type = VehicleType.new(opts)
    %{model | vehicle_types: vehicle_types ++ [vehicle_type]}
  end

  @doc """
  Adds a client group to the model.

  See `ExVrp.ClientGroup.new/1` for available options.

  ## Example

      model
      |> ExVrp.Model.add_client_group(clients: [0, 1, 2], required: true)

  """
  @spec add_client_group(t(), keyword()) :: t()
  def add_client_group(%__MODULE__{client_groups: groups} = model, opts) do
    group = ClientGroup.new(opts)
    %{model | client_groups: groups ++ [group]}
  end

  @doc """
  Sets custom distance matrices.

  If not provided, Euclidean distances are computed from coordinates.

  ## Example

      model
      |> ExVrp.Model.set_distance_matrices([matrix1, matrix2])

  """
  @spec set_distance_matrices(t(), [[[non_neg_integer()]]]) :: t()
  def set_distance_matrices(%__MODULE__{} = model, matrices) do
    %{model | distance_matrices: matrices}
  end

  @doc """
  Sets custom duration matrices.

  If not provided, distances are used as durations.

  ## Example

      model
      |> ExVrp.Model.set_duration_matrices([matrix1, matrix2])

  """
  @spec set_duration_matrices(t(), [[[non_neg_integer()]]]) :: t()
  def set_duration_matrices(%__MODULE__{} = model, matrices) do
    %{model | duration_matrices: matrices}
  end

  @doc """
  Validates the model and returns any errors.

  Returns `:ok` if valid, `{:error, reasons}` otherwise.
  """
  @spec validate(t()) :: :ok | {:error, [String.t()]}
  def validate(%__MODULE__{} = model) do
    errors =
      []
      |> validate_has_depots(model)
      |> validate_has_vehicle_types(model)
      |> validate_capacity_dimensions(model)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  defp validate_has_depots(errors, %{depots: []}) do
    ["Model must have at least one depot" | errors]
  end

  defp validate_has_depots(errors, _model), do: errors

  defp validate_has_vehicle_types(errors, %{vehicle_types: []}) do
    ["Model must have at least one vehicle type" | errors]
  end

  defp validate_has_vehicle_types(errors, _model), do: errors

  defp validate_capacity_dimensions(errors, %{vehicle_types: []}) do
    errors
  end

  defp validate_capacity_dimensions(errors, %{clients: clients, vehicle_types: vehicle_types}) do
    dims = length(hd(vehicle_types).capacity)

    invalid_indices =
      clients
      |> Enum.with_index()
      |> Enum.filter(fn {c, _} -> length(c.delivery) != dims or length(c.pickup) != dims end)
      |> Enum.map(fn {_, i} -> i end)

    case invalid_indices do
      [] -> errors
      _ -> ["Clients #{inspect(invalid_indices)} have mismatched capacity dimensions" | errors]
    end
  end

  @doc """
  Converts the model to ProblemData for the solver.

  This is called internally by `ExVrp.solve/2`.
  """
  @spec to_problem_data(t()) :: {:ok, reference()} | {:error, term()}
  def to_problem_data(%__MODULE__{} = model) do
    case validate(model) do
      :ok -> ExVrp.Native.create_problem_data(model)
      {:error, _} = error -> error
    end
  end
end

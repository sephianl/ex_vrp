defmodule ExVrp.Literature.BenchmarkGroup do
  @moduledoc """
  A group of literature instances: where they are downloaded from, the rounding their
  best-known costs follow, the per-instance time budget, and PyVRP's published average gap
  when the group follows PyVRP's benchmarking protocol.

  Budgets are seconds on a CPU with the group's reference single-thread PassMark score, as
  PyVRP's protocol states them (`docs/source/dev/benchmarking.rst`). The published gaps are
  from `docs/source/setup/benchmarks.rst`: averages over the full set, ten seeds, one core
  per run, against the best-known solutions in `PyVRP/Instances`.
  """

  @typedoc "The archive, the directory inside it, and a glob for the instance files there."
  @type source :: {:pyvrp_instances | :cvrplib, String.t(), String.t()}
  @type budget :: {:per_client, number()} | {:fixed, number()}

  @type t :: %__MODULE__{
          id: atom(),
          source: source(),
          round_func: ExVrp.Read.round_func(),
          budget: budget(),
          reference_passmark: pos_integer(),
          pyvrp_published_gaps: %{String.t() => float()} | nil
        }

  @enforce_keys [:id, :source, :round_func, :budget, :reference_passmark]
  defstruct [:id, :source, :round_func, :budget, :reference_passmark, pyvrp_published_gaps: nil]

  @spec all() :: [t()]
  def all do
    [
      %__MODULE__{
        id: :cvrp,
        source: {:pyvrp_instances, "CVRP", "X-n*.vrp"},
        round_func: :round,
        budget: {:per_client, 2.4},
        reference_passmark: 2183,
        pyvrp_published_gaps: %{"0.13.0" => 0.31, "0.14.0" => 0.31}
      },
      %__MODULE__{
        id: :hfvrp,
        source: {:pyvrp_instances, "HFVRP", "*.vrp"},
        round_func: :exact,
        budget: {:per_client, 2.4},
        reference_passmark: 2000,
        pyvrp_published_gaps: %{"0.13.0" => 0.53, "0.14.0" => 0.51}
      },
      %__MODULE__{
        id: :mtvrptwr,
        source: {:pyvrp_instances, "MTVRPTWR", "*.vrp"},
        round_func: :dimacs,
        budget: {:fixed, 600},
        reference_passmark: 2000,
        pyvrp_published_gaps: %{"0.13.0" => 0.33, "0.14.0" => 0.58}
      },
      %__MODULE__{
        id: :mdvrptw,
        source: {:pyvrp_instances, "MDVRPTW", "*.vrp"},
        round_func: :exact,
        budget: {:fixed, 3600},
        reference_passmark: 2000,
        pyvrp_published_gaps: %{"0.13.0" => 0.69, "0.14.0" => 0.81}
      },
      %__MODULE__{
        id: :solomon,
        source: {:cvrplib, "Solomon", "*.txt"},
        round_func: :dimacs,
        budget: {:per_client, 2.4},
        reference_passmark: 2000
      },
      %__MODULE__{
        id: :hg200,
        source: {:cvrplib, "Holmberger", "*_2_*.txt"},
        round_func: :dimacs,
        budget: {:per_client, 2.4},
        reference_passmark: 2000
      },
      %__MODULE__{
        id: :dimacs,
        source: {:cvrplib, "DIMACS", "*.vrp"},
        round_func: :round,
        budget: {:per_client, 2.4},
        reference_passmark: 2000
      }
    ]
  end

  @spec fetch(atom()) :: {:ok, t()} | :error
  def fetch(id) do
    case Enum.find(all(), &(&1.id == id)) do
      nil -> :error
      group -> {:ok, group}
    end
  end

  @spec id_from_name(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def id_from_name(name) do
    case Enum.find(all(), &(Atom.to_string(&1.id) == name)) do
      nil -> {:error, "unknown benchmark group #{inspect(name)}"}
      group -> {:ok, group.id}
    end
  end

  @doc "The budget in seconds for an instance with `num_clients` clients on a CPU with the given PassMark."
  @spec budget_seconds(t(), pos_integer(), pos_integer() | nil, number()) :: float()
  def budget_seconds(%__MODULE__{} = group, num_clients, passmark, budget_scale) do
    group.budget
    |> reference_seconds(num_clients)
    |> Kernel.*(speed_ratio(group, passmark) * budget_scale)
    |> Float.round(1)
  end

  defp speed_ratio(_group, nil = _passmark), do: 1.0
  defp speed_ratio(%__MODULE__{reference_passmark: reference}, passmark), do: reference / passmark

  defp reference_seconds({:per_client, seconds}, num_clients), do: seconds * num_clients
  defp reference_seconds({:fixed, seconds}, _num_clients), do: seconds
end

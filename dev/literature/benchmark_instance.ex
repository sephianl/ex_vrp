defmodule ExVrp.Literature.BenchmarkInstance do
  @moduledoc """
  One literature instance as the manifest records it. Costs are in the units our solver
  reports for the group's rounding.

  `bks` is the cost of the source's own best-known solution, which is what PyVRP's
  published gaps are measured against. `cvrplib_bound` is CVRPLib's current upper bound,
  which can be newer and lower, and `optimal` says whether that bound is proven optimal.
  """

  alias ExVrp.Literature.BenchmarkGroup

  @type t :: %__MODULE__{
          name: String.t(),
          group: atom(),
          num_clients: pos_integer(),
          path: String.t(),
          bks: non_neg_integer(),
          cvrplib_bound: non_neg_integer() | nil,
          optimal: boolean()
        }

  @enforce_keys [:name, :group, :num_clients, :path, :bks]
  defstruct [:name, :group, :num_clients, :path, :bks, cvrplib_bound: nil, optimal: false]

  @doc "The lowest known cost: CVRPLib's bound when it has a newer one, else the source's own."
  @spec best_known(t()) :: non_neg_integer()
  def best_known(%__MODULE__{bks: bks, cvrplib_bound: nil}), do: bks
  def best_known(%__MODULE__{bks: bks, cvrplib_bound: bound}), do: min(bks, bound)

  @spec group(t()) :: BenchmarkGroup.t()
  def group(%__MODULE__{group: id}) do
    {:ok, group} = BenchmarkGroup.fetch(id)
    group
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = instance), do: instance |> Map.from_struct() |> Map.update!(:group, &Atom.to_string/1)

  @spec from_json(map()) :: t()
  def from_json(%{"name" => name, "group" => group, "num_clients" => num_clients, "path" => path, "bks" => bks} = json) do
    {:ok, group_id} = BenchmarkGroup.id_from_name(group)

    %__MODULE__{
      name: name,
      group: group_id,
      num_clients: num_clients,
      path: path,
      bks: bks,
      cvrplib_bound: json["cvrplib_bound"],
      optimal: json["optimal"]
    }
  end
end

defmodule ExVrp.Statistics do
  @moduledoc """
  Statistics about the search progress.

  Collects data about solution costs and feasibility during optimization,
  allowing analysis of the search trajectory.

  ## Example

      stats = ExVrp.Statistics.new()
      stats = ExVrp.Statistics.collect(stats, current, candidate, best, cost_evaluator)
      Enum.each(stats, fn datum -> IO.inspect(datum) end)

  """

  alias ExVrp.Native

  @type datum :: %{
          current_cost: integer(),
          current_feas: boolean(),
          candidate_cost: integer(),
          candidate_feas: boolean(),
          best_cost: integer(),
          best_feas: boolean()
        }

  @type t :: %__MODULE__{
          runtimes: [float()],
          num_iterations: non_neg_integer(),
          data: [datum()],
          clock: integer(),
          collect_stats: boolean()
        }

  defstruct runtimes: [],
            num_iterations: 0,
            data: [],
            clock: nil,
            collect_stats: true

  @doc """
  Creates a new Statistics object.

  ## Options

  - `:collect_stats` - Whether to collect statistics. Can be turned off to
    avoid excessive memory use on long runs. Defaults to `true`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    collect_stats = Keyword.get(opts, :collect_stats, true)

    %__MODULE__{
      runtimes: [],
      num_iterations: 0,
      data: [],
      clock: System.monotonic_time(:microsecond),
      collect_stats: collect_stats
    }
  end

  @doc """
  Returns whether this Statistics object is collecting data.
  """
  @spec collecting?(t()) :: boolean()
  def collecting?(%__MODULE__{collect_stats: collect_stats}), do: collect_stats

  @doc """
  Collects iteration statistics.

  ## Parameters

  - `stats` - The Statistics object
  - `current` - The current solution reference
  - `candidate` - The candidate solution reference
  - `best` - The best solution reference
  - `cost_evaluator` - CostEvaluator reference used to compute costs
  """
  @spec collect(t(), reference(), reference(), reference(), reference()) :: t()
  def collect(%__MODULE__{collect_stats: false} = stats, _current, _candidate, _best, _cost_eval) do
    stats
  end

  def collect(%__MODULE__{} = stats, current, candidate, best, cost_evaluator) do
    now = System.monotonic_time(:microsecond)
    runtime = (now - stats.clock) / 1_000_000.0

    datum = %{
      current_cost: Native.solution_penalised_cost(current, cost_evaluator),
      current_feas: Native.solution_is_feasible(current),
      candidate_cost: Native.solution_penalised_cost(candidate, cost_evaluator),
      candidate_feas: Native.solution_is_feasible(candidate),
      best_cost: Native.solution_penalised_cost(best, cost_evaluator),
      best_feas: Native.solution_is_feasible(best)
    }

    %{
      stats
      | runtimes: stats.runtimes ++ [runtime],
        num_iterations: stats.num_iterations + 1,
        data: stats.data ++ [datum],
        clock: now
    }
  end

  @doc """
  Writes this Statistics object to a CSV file.

  ## Parameters

  - `stats` - The Statistics object
  - `path` - File path to write to
  - `opts` - Options (`:delimiter` defaults to `,`)
  """
  @spec to_csv(t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def to_csv(%__MODULE__{} = stats, path, opts \\ []) do
    delimiter = Keyword.get(opts, :delimiter, ",")

    header = [
      "runtime",
      "current_cost",
      "current_feas",
      "candidate_cost",
      "candidate_feas",
      "best_cost",
      "best_feas"
    ]

    rows =
      stats.runtimes
      |> Enum.zip(stats.data)
      |> Enum.map(fn {runtime, datum} ->
        [
          runtime,
          datum.current_cost,
          bool_to_int(datum.current_feas),
          datum.candidate_cost,
          bool_to_int(datum.candidate_feas),
          datum.best_cost,
          bool_to_int(datum.best_feas)
        ]
      end)

    content = Enum.map_join([header | rows], "\n", &Enum.join(&1, delimiter))

    File.write(path, content <> "\n")
  end

  @doc """
  Reads a Statistics object from a CSV file.

  ## Parameters

  - `path` - File path to read from
  - `opts` - Options (`:delimiter` defaults to `,`)
  """
  @spec from_csv(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_csv(path, opts \\ []) do
    delimiter = Keyword.get(opts, :delimiter, ",")

    case File.read(path) do
      {:ok, content} ->
        [_header | rows] =
          content
          |> String.trim()
          |> String.split("\n")
          |> Enum.map(&String.split(&1, delimiter))

        {runtimes, data} =
          rows
          |> Enum.map(&parse_row/1)
          |> Enum.unzip()

        stats = %__MODULE__{
          runtimes: runtimes,
          num_iterations: length(data),
          data: data,
          clock: System.monotonic_time(:microsecond),
          collect_stats: true
        }

        {:ok, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_row([runtime, curr_cost, curr_feas, cand_cost, cand_feas, best_cost, best_feas]) do
    {runtime, _} = Float.parse(runtime)

    datum = %{
      current_cost: String.to_integer(curr_cost),
      current_feas: int_to_bool(curr_feas),
      candidate_cost: String.to_integer(cand_cost),
      candidate_feas: int_to_bool(cand_feas),
      best_cost: String.to_integer(best_cost),
      best_feas: int_to_bool(best_feas)
    }

    {runtime, datum}
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp int_to_bool("1"), do: true
  defp int_to_bool("0"), do: false
  defp int_to_bool(1), do: true
  defp int_to_bool(0), do: false

  # Implement Enumerable protocol for iterating over data
  defimpl Enumerable do
    def count(%ExVrp.Statistics{data: data}), do: {:ok, length(data)}

    def member?(%ExVrp.Statistics{data: data}, element), do: {:ok, element in data}

    def reduce(%ExVrp.Statistics{data: data}, acc, fun) do
      Enumerable.List.reduce(data, acc, fun)
    end

    def slice(%ExVrp.Statistics{data: data}) do
      {:ok, length(data), &Enum.slice(data, &1, &2)}
    end
  end
end

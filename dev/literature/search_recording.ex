defmodule ExVrp.Literature.SearchRecording do
  @moduledoc """
  Everything a solve reports while it runs, kept for its literature record: the initial
  solution and when it was ready, and every progress report of the search (about once a
  second) as a column table. The best-cost `trace` derives from those reports plus the
  final cost, since the last improvement can land between two reports.

  The solve's `on_progress` callback runs in the solving process, which is the job's own,
  so reports are sent to it and collected from its mailbox once the solve returns.
  """

  @progress_columns ~w(elapsed_ms iteration best_cost current_cost feasible improvements restarts
                       num_routes num_clients best_distance total_duration)

  @spec reporter(pid(), integer(), (map() -> any())) :: (map() -> any())
  def reporter(job, started_ms, on_search_progress) do
    fn
      %{elapsed_ms: _elapsed_ms} = progress ->
        send(job, {:search_progress, progress})
        on_search_progress.(progress)

      %{stage: :initial_solution} = initial_solution ->
        send(job, {:initial_solution, System.monotonic_time(:millisecond) - started_ms, initial_solution})

      %{stage: _other_setup_stage} ->
        :ok
    end
  end

  @doc "The recorded fields, collected from the job's mailbox after its solve returned."
  @spec collect(map()) :: map()
  def collect(solve_record) do
    {initial_solution, progress} = drain(nil, [])
    rows = Enum.map(progress, &progress_row/1)

    %{
      "initial_solution" => initial_solution,
      "progress" => %{"columns" => @progress_columns, "rows" => rows},
      "trace" => best_cost_trace(rows, final_point(solve_record))
    }
  end

  defp final_point(%{"objective" => objective, "search_ms" => search_ms}), do: [search_ms, objective]
  defp final_point(%{"objective" => nil = _failed_solve}), do: [0, nil]

  defp drain(initial_solution, progress) do
    receive do
      {:search_progress, report} -> drain(initial_solution, [report | progress])
      {:initial_solution, at_ms, report} -> drain(initial_solution_fields(at_ms, report), progress)
    after
      0 -> {initial_solution, Enum.reverse(progress)}
    end
  end

  defp initial_solution_fields(at_ms, report) do
    %{
      "at_ms" => at_ms,
      "feasible" => report.is_feasible,
      "distance" => report.best_distance,
      "duration" => report.total_duration,
      "num_routes" => report.num_routes,
      "num_clients" => report.num_clients
    }
  end

  defp progress_row(report) do
    [
      report.elapsed_ms,
      report.iteration,
      finite(report.best_cost),
      finite(report.current_cost),
      report.is_feasible,
      report.improvements,
      report.restarts,
      report.num_routes,
      report.num_clients,
      report.best_distance,
      report.total_duration
    ]
  end

  defp finite(:infinity), do: nil
  defp finite(cost), do: cost

  defp best_cost_trace(rows, final_point) do
    rows
    |> Enum.map(fn [elapsed_ms, _iteration, best_cost | _rest] -> [elapsed_ms, best_cost] end)
    |> Kernel.++([final_point])
    |> Enum.filter(fn [_elapsed_ms, cost] -> is_number(cost) end)
    |> Enum.dedup_by(fn [_elapsed_ms, cost] -> cost end)
  end
end

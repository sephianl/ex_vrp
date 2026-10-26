defmodule ExVrp.Literature.ProgressBoard do
  @moduledoc """
  The live view of a literature run: every minute, one line per running solve with its
  elapsed time and current gap to the best-known cost, and one line per finished solve.
  Solves report to it from their `on_progress` callbacks.
  """

  use GenServer

  alias ExVrp.Literature.Gap

  @print_interval_ms 60_000

  @spec start_link(non_neg_integer()) :: GenServer.on_start()
  def start_link(total_jobs), do: GenServer.start_link(__MODULE__, total_jobs)

  @spec progress(pid(), String.t(), map()) :: :ok
  def progress(board, job_label, status), do: GenServer.cast(board, {:progress, job_label, status})

  @spec finished(pid(), String.t(), String.t()) :: :ok
  def finished(board, job_label, outcome), do: GenServer.cast(board, {:finished, job_label, outcome})

  @impl GenServer
  def init(total_jobs) do
    schedule_print()
    {:ok, %{total: total_jobs, done: 0, running: %{}}}
  end

  @impl GenServer
  def handle_cast({:progress, job_label, status}, state), do: {:noreply, put_in(state.running[job_label], status)}

  def handle_cast({:finished, job_label, outcome}, state) do
    done = state.done + 1
    Mix.shell().info("[#{done}/#{state.total}] #{job_label}: #{outcome}")
    {:noreply, %{state | done: done, running: Map.delete(state.running, job_label)}}
  end

  @impl GenServer
  def handle_info(:print, state) do
    state.running
    |> Enum.sort()
    |> Enum.each(fn {job_label, status} -> Mix.shell().info("  … #{job_label}: #{status_line(status)}") end)

    schedule_print()
    {:noreply, state}
  end

  defp status_line(%{elapsed_s: elapsed_s, budget_s: budget_s, gap: gap}),
    do: "#{round(elapsed_s)}/#{round(budget_s)}s, gap #{Gap.format(gap)}"

  defp schedule_print, do: Process.send_after(self(), :print, @print_interval_ms)
end

defmodule ExVrp.Literature.SearchRecordingTest do
  use ExUnit.Case, async: true

  alias ExVrp.Literature.SearchRecording

  defp progress(elapsed_ms, iteration, best_cost) do
    %{
      elapsed_ms: elapsed_ms,
      iteration: iteration,
      best_cost: best_cost,
      current_cost: 999,
      is_feasible: best_cost != :infinity,
      improvements: 1,
      restarts: 0,
      num_routes: 2,
      num_clients: 10,
      best_distance: 500,
      total_duration: 700
    }
  end

  test "records the initial solution, every progress report, and the best-cost trace" do
    reporter = SearchRecording.reporter(self(), System.monotonic_time(:millisecond), fn _progress -> :ok end)

    reporter.(%{
      stage: :initial_solution,
      is_feasible: true,
      best_distance: 900,
      total_duration: 1000,
      num_routes: 3,
      num_clients: 10
    })

    reporter.(progress(1000, 400, :infinity))
    reporter.(progress(2000, 800, 520))
    reporter.(progress(3000, 1200, 520))

    recorded = SearchRecording.collect(%{"objective" => 510, "search_ms" => 3400})

    assert %{"feasible" => true, "distance" => 900, "num_routes" => 3} = recorded["initial_solution"]
    assert hd(recorded["progress"]["columns"]) == "elapsed_ms"

    assert Enum.map(recorded["progress"]["rows"], &Enum.take(&1, 4)) == [
             [1000, 400, nil, 999],
             [2000, 800, 520, 999],
             [3000, 1200, 520, 999]
           ]

    assert recorded["trace"] == [[2000, 520], [3400, 510]]
  end

  test "a failed solve records no trace" do
    assert %{"trace" => [], "initial_solution" => nil} = SearchRecording.collect(%{"objective" => nil})
  end
end

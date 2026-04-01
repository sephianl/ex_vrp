alias ExVrp.StoppingCriteria

Logger.configure(level: :warning)

# Load the largest March 30th benchmark
file =
  Path.join(
    :code.priv_dir(:ex_vrp),
    "benchmark_data/production/2026-03-30_5d6a2c58-7a27-4092-ae02-b1f5f1833dff_model.etf"
  )

model = file |> File.read!() |> Base.decode64!() |> :erlang.binary_to_term()

n = ExVrp.Model.num_locations(model)

plannable =
  model.clients
  |> Enum.filter(&(&1.prize > 0))
  |> Enum.group_by(& &1.group)
  |> Enum.reduce(0, fn
    {nil, clients}, acc -> acc + length(clients)
    {_group_idx, _clients}, acc -> acc + 1
  end)

cores = System.schedulers_online()

IO.puts("Model: #{Path.basename(file)}")
IO.puts("Locations: #{n}, Plannable clients: #{plannable}")
IO.puts("Schedulers online: #{cores}")
IO.puts("")

timeout_s = 30
base_seed = 42

# Focus around the sweet spot: total tasks ~4-12
configs = [
  # {parallel_jobs, num_starts} — total tasks
  #  1  (baseline)
  {1, 1},
  #  4
  {1, 4},
  #  6
  {1, 6},
  #  8
  {1, 8},
  # 10
  {1, 10},
  # 12
  {1, 12},
  #  2
  {2, 1},
  #  4
  {2, 2},
  #  6
  {2, 3},
  #  8
  {2, 4},
  # 10
  {2, 5},
  # 12
  {2, 6},
  #  3
  {3, 1},
  #  6
  {3, 2},
  #  9
  {3, 3},
  # 12
  {3, 4},
  #  4
  {4, 1},
  #  8
  {4, 2},
  # 12
  {4, 3},
  #  6
  {6, 1},
  # 12
  {6, 2},
  #  8
  {8, 1}
]

IO.puts("Grid: parallel_jobs x num_starts, #{timeout_s}s timeout each")
IO.puts("")

IO.puts(String.duplicate("-", 100))

IO.puts(
  String.pad_trailing("jobs", 6) <>
    String.pad_trailing("starts", 8) <>
    String.pad_trailing("total", 8) <>
    String.pad_trailing("best_dist", 12) <>
    String.pad_trailing("feasible?", 12) <>
    String.pad_trailing("clients", 12) <>
    String.pad_trailing("routes", 10) <>
    String.pad_trailing("tot_iters", 12) <>
    String.pad_trailing("runtime", 10)
)

IO.puts(String.duplicate("-", 100))

for {parallel_jobs, num_starts} <- configs do
  total = parallel_jobs * num_starts

  tasks =
    for job_idx <- 0..(parallel_jobs - 1) do
      seed = base_seed + job_idx * num_starts

      Task.async(fn ->
        stop = StoppingCriteria.max_runtime(timeout_s)
        ExVrp.solve(model, stop: stop, seed: seed, num_starts: num_starts)
      end)
    end

  results = Task.await_many(tasks, :infinity)

  ok_results =
    Enum.flat_map(results, fn
      {:ok, result} -> [result]
      _ -> []
    end)

  best =
    Enum.min_by(ok_results, fn r ->
      case ExVrp.IteratedLocalSearch.Result.cost(r) do
        :infinity -> {1, 0}
        cost -> {0, cost}
      end
    end)

  total_iters =
    Enum.sum(
      Enum.map(ok_results, fn r ->
        r.stats[:total_iterations] || r.num_iterations
      end)
    )

  runtime = Enum.max(Enum.map(ok_results, & &1.runtime))

  IO.puts(
    String.pad_trailing("#{parallel_jobs}", 6) <>
      String.pad_trailing("#{num_starts}", 8) <>
      String.pad_trailing("#{total}", 8) <>
      String.pad_trailing("#{best.best.distance}", 12) <>
      String.pad_trailing("#{best.best.is_feasible}", 12) <>
      String.pad_trailing("#{best.best.num_clients}/#{plannable}", 12) <>
      String.pad_trailing("#{length(best.best.routes)}", 10) <>
      String.pad_trailing("#{total_iters}", 12) <>
      String.pad_trailing("#{runtime}ms", 10)
  )
end

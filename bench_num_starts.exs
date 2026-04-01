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

IO.puts("Model: #{Path.basename(file)}")
IO.puts("Locations: #{n}, Plannable clients: #{plannable}")
IO.puts("Schedulers online: #{System.schedulers_online()}")
IO.puts("")

timeout_s = 30
seed = 42
num_starts_list = [1, 2, 4, 8, 16, 32]

IO.puts("Running configs SEQUENTIALLY with #{timeout_s}s timeout, seed=#{seed}")
IO.puts("(each config gets the full CPU)")
IO.puts("")

IO.puts(String.duplicate("-", 85))

IO.puts(
  String.pad_trailing("num_starts", 12) <>
    String.pad_trailing("distance", 12) <>
    String.pad_trailing("feasible?", 12) <>
    String.pad_trailing("clients", 12) <>
    String.pad_trailing("routes", 10) <>
    String.pad_trailing("tot_iters", 12) <>
    String.pad_trailing("runtime", 10)
)

IO.puts(String.duplicate("-", 85))

for num_starts <- num_starts_list do
  stop = StoppingCriteria.max_runtime(timeout_s)
  {:ok, result} = ExVrp.solve(model, stop: stop, seed: seed, num_starts: num_starts)
  total_iters = result.stats[:total_iterations] || result.num_iterations

  IO.puts(
    String.pad_trailing("#{num_starts}", 12) <>
      String.pad_trailing("#{result.best.distance}", 12) <>
      String.pad_trailing("#{result.best.is_feasible}", 12) <>
      String.pad_trailing("#{result.best.num_clients}/#{plannable}", 12) <>
      String.pad_trailing("#{length(result.best.routes)}", 10) <>
      String.pad_trailing("#{total_iters}", 12) <>
      String.pad_trailing("#{result.runtime}ms", 10)
  )
end

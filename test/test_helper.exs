# Exclude NIF-dependent tests until C++ bindings are implemented.
# Run with `mix test --include nif_required` to include them.
ExUnit.configure(exclude: [:production_benchmark, :production_benchmark_quick, :benchmark])
ExUnit.start()

# Suppress info-level solver logs during tests to keep CI output clean.
Logger.configure(level: :warning)
Application.ensure_all_started(:credo)

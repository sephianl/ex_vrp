# Exclude NIF-dependent tests until C++ bindings are implemented.
# Run with `mix test --include nif_required` to include them.
ExUnit.configure([])
ExUnit.start()

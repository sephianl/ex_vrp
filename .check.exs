[
  tools: [
    {:sobelow, "mix sobelow --exit --skip"},
    {:credence, "mix credence --exit"},
    {:ex_dna, "mix ex_dna"},

    # Reach — program-dependence-graph release-safety. See .reach.exs.
    # Only arch and smells gate the build; dead-code and candidates are advisory
    # (no Mix.raise path) and run on demand. Matches reach's own `mix ci`.
    # Combined invocation shares one project load (see Reach.CLI.Commands.Check
    # share_project?/2) — avoids Task.async_stream 5s timeouts under parallel load.
    {:reach, "mix reach.check --arch --smells --strict"}
    # `--changed --base main` requires the base commit locally; run in CI separately.
  ]
]

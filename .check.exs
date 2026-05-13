[
  tools: [
    {:sobelow, "mix sobelow --exit --skip"},

    # Reach — program-dependence-graph release-safety. See .reach.exs.
    {:reach_arch, "mix reach.check --arch"},
    {:reach_dead_code, "mix reach.check --dead-code"},
    {:reach_smells, "mix reach.check --smells"},
    {:reach_candidates, "mix reach.check --candidates"}
    # `--changed --base main` requires the base commit locally; run in CI separately.
  ]
]

[
  tools: [
    {:sobelow, "mix sobelow --exit --skip"},
    {:ex_dna, "mix ex_dna"},

    # Reach — program-dependence-graph release-safety. See .reach.exs.
    # Chained sequentially so the four sub-checks share one _build lock.
    {:reach,
     "mix reach.check --arch && mix reach.check --dead-code && mix reach.check --smells && mix reach.check --candidates"}
    # `--changed --base main` requires the base commit locally; run in CI separately.
  ]
]

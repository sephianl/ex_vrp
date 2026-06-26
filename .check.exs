[
  tools: [
    {:sobelow, "mix sobelow --exit --skip"},
    {:ex_dna, "mix ex_dna"}
    # Credence and Reach each run as their own pre-commit hook (mix-credence,
    # mix-reach in devenv.nix) and dedicated CI steps. Splitting them out of
    # `mix check` avoids `_build` lock contention with dialyzer/ex_doc and makes
    # each gate's failure surface unambiguous in CI logs.
  ]
]

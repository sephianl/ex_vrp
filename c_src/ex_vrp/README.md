# Vendored PyVRP C++ core (adapted fork)

This folder is an **adapted copy** of [PyVRP](https://github.com/PyVRP/PyVRP)'s
C++ search core — it is **not** pristine upstream. ExVrp drives this core from
Elixir via NIFs (`../ex_vrp_nif.cpp`) and replaces PyVRP's genetic-algorithm
layer (population / crossover / diversity / repair) with iterated local search,
so those upstream components are intentionally not vendored here.

## Baseline and local patches

- **Upstream baseline:** PyVRP **v0.13.4** (the `pyvrp::` namespace and `PYVRP_`
  header guards are kept to ease future upstream merges).
- About half the files are byte-identical to upstream; the rest carry deliberate
  ExVrp patches: same-vehicle groups, forbidden/shift windows, reload &
  multi-trip cost, depot-service-duration removal, and NIF/ILS integration.

## Syncing a new upstream release

Run `scripts/vendor_pyvrp.sh` (set `PYVRP_VERSION=vX.Y.Z`). It never overwrites:
files identical to upstream are left alone, and drifted (locally-patched) files
get a `*.upstream` sidecar for a deliberate 3-way merge. Sync to tagged releases
only — not upstream `main`.

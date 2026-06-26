#!/bin/bash
# Check ExVrp's vendored PyVRP C++ core against a pinned upstream release.
#
# IMPORTANT: this script does NOT blindly overwrite files. Roughly half of the
# vendored tree carries deliberate ExVrp patches (same-vehicle groups, forbidden
# windows, reload/multi-trip, depot-service removal, NIF/ILS integration). A
# straight re-download would destroy those. Instead, for every file this script:
#   - leaves it untouched if it is byte-identical to upstream ("in sync"), or
#   - writes the upstream version next to it as <file>.upstream and flags it as
#     DRIFT, so you can do a deliberate 3-way merge by hand.
#
# We vendor ONLY the C++ search core. PyVRP's genetic-algorithm layer
# (population / SubPopulation / crossover / diversity / repair) is intentionally
# NOT vendored: ExVrp replaces it with iterated local search in Elixir.
#
# Usage:   PYVRP_VERSION=v0.13.4 scripts/vendor_pyvrp.sh
# Baseline: ExVrp's pristine files are in sync with v0.13.0; the only known drift
# from v0.13.4 is the #1045 group-guard fix, already ported into LocalSearch.cpp.

set -euo pipefail

PYVRP_VERSION="${PYVRP_VERSION:-v0.13.4}"
PYVRP_REPO="https://raw.githubusercontent.com/PyVRP/PyVRP/${PYVRP_VERSION}"
TARGET_DIR="c_src/ex_vrp"

# Files we actually vendor (relative to the upstream pyvrp/cpp/ directory).
CORE_FILES=(
    bindings.cpp bindings.h
    CostEvaluator.cpp CostEvaluator.h
    DurationSegment.cpp DurationSegment.h
    DynamicBitset.cpp DynamicBitset.h
    LoadSegment.cpp LoadSegment.h
    Matrix.h Measure.h
    ProblemData.cpp ProblemData.h
    RandomNumberGenerator.cpp RandomNumberGenerator.h
    Route.cpp Route.h
    Solution.cpp Solution.h
    Trip.cpp Trip.h
)

SEARCH_FILES=(
    search/bindings.cpp
    search/Exchange.h
    search/LocalSearch.cpp search/LocalSearch.h
    search/LocalSearchOperator.h
    search/PerturbationManager.cpp search/PerturbationManager.h
    search/primitives.cpp search/primitives.h
    search/RelocateWithDepot.cpp search/RelocateWithDepot.h
    search/Route.cpp search/Route.h
    search/SearchSpace.cpp search/SearchSpace.h
    search/Solution.cpp search/Solution.h
    search/SwapRoutes.cpp search/SwapRoutes.h
    search/SwapStar.cpp search/SwapStar.h
    search/SwapTails.cpp search/SwapTails.h
)

echo "Checking ${TARGET_DIR} against pristine PyVRP ${PYVRP_VERSION}..."
echo

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

in_sync=0
drift=()
missing=()

check_file() {
    local rel="$1"
    local local_path="${TARGET_DIR}/${rel}"
    local up="${tmp}/upstream"

    local code
    code="$(curl -sL -o "${up}" -w '%{http_code}' "${PYVRP_REPO}/pyvrp/cpp/${rel}")"
    if [ "${code}" != "200" ]; then
        echo "  ?? ${rel} (upstream fetch ${code} — not present in ${PYVRP_VERSION})"
        return
    fi

    if [ ! -f "${local_path}" ]; then
        cp "${up}" "${local_path}"
        missing+=("${rel}")
        echo "  ++ ${rel} (was absent locally — added from upstream)"
        return
    fi

    if cmp -s "${local_path}" "${up}"; then
        in_sync=$((in_sync + 1))
    else
        cp "${up}" "${local_path}.upstream"
        drift+=("${rel}")
        echo "  !! ${rel} -> wrote ${rel}.upstream (DRIFT: 3-way merge by hand)"
    fi
}

for f in "${CORE_FILES[@]}" "${SEARCH_FILES[@]}"; do
    check_file "${f}"
done

echo
echo "Summary vs ${PYVRP_VERSION}:"
echo "  in sync : ${in_sync}"
echo "  drift   : ${#drift[@]} (see *.upstream sidecars; merge then delete them)"
echo "  added   : ${#missing[@]}"
if [ "${#drift[@]}" -gt 0 ]; then
    echo
    echo "Drifted files (carry local patches — DO NOT blind-overwrite):"
    printf '  - %s\n' "${drift[@]}"
fi

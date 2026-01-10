#!/bin/bash
# Script to vendor PyVRP C++ source code
# This downloads the required C++ files from the PyVRP repository

set -euo pipefail

PYVRP_VERSION="${PYVRP_VERSION:-v0.9.0}"
PYVRP_REPO="https://raw.githubusercontent.com/PyVRP/PyVRP/${PYVRP_VERSION}"
TARGET_DIR="c_src/pyvrp"

echo "Vendoring PyVRP C++ source (${PYVRP_VERSION})..."

# Create target directories
mkdir -p "${TARGET_DIR}"
mkdir -p "${TARGET_DIR}/search"
mkdir -p "${TARGET_DIR}/crossover"
mkdir -p "${TARGET_DIR}/diversity"
mkdir -p "${TARGET_DIR}/repair"

# Core C++ files (v0.9.0 structure)
CORE_FILES=(
    "CostEvaluator.cpp"
    "CostEvaluator.h"
    "DistanceSegment.cpp"
    "DistanceSegment.h"
    "DurationSegment.cpp"
    "DurationSegment.h"
    "DynamicBitset.cpp"
    "DynamicBitset.h"
    "LoadSegment.cpp"
    "LoadSegment.h"
    "Matrix.h"
    "Measure.h"
    "ProblemData.cpp"
    "ProblemData.h"
    "RandomNumberGenerator.cpp"
    "RandomNumberGenerator.h"
    "Solution.cpp"
    "Solution.h"
    "SubPopulation.cpp"
    "SubPopulation.h"
)

# Search algorithm files
SEARCH_FILES=(
    "Exchange.h"
    "LocalSearch.cpp"
    "LocalSearch.h"
    "LocalSearchOperator.h"
    "MoveTwoClientsReversed.h"
    "PerturbationManager.cpp"
    "PerturbationManager.h"
    "RelocateWithDepot.cpp"
    "RelocateWithDepot.h"
    "Route.cpp"
    "Route.h"
    "SearchSpace.cpp"
    "SearchSpace.h"
    "Solution.cpp"
    "Solution.h"
    "SwapRoutes.cpp"
    "SwapRoutes.h"
    "SwapStar.cpp"
    "SwapStar.h"
    "SwapTails.cpp"
    "SwapTails.h"
    "TwoOpt.h"
    "primitives.cpp"
    "primitives.h"
)

# Crossover files
CROSSOVER_FILES=(
    "SelectiveRouteExchange.cpp"
    "SelectiveRouteExchange.h"
    "bindings.cpp"
)

# Diversity files
DIVERSITY_FILES=(
    "broken_pairs_distance.cpp"
    "broken_pairs_distance.h"
    "bindings.cpp"
)

# Repair files
REPAIR_FILES=(
    "greedy_repair.cpp"
    "greedy_repair.h"
    "nearest_route_insert.cpp"
    "nearest_route_insert.h"
    "bindings.cpp"
)

echo "Downloading core files..."
for file in "${CORE_FILES[@]}"; do
    echo "  - ${file}"
    curl -sL "${PYVRP_REPO}/pyvrp/cpp/${file}" -o "${TARGET_DIR}/${file}" || echo "    (failed, skipping)"
done

echo "Downloading search files..."
for file in "${SEARCH_FILES[@]}"; do
    echo "  - search/${file}"
    curl -sL "${PYVRP_REPO}/pyvrp/cpp/search/${file}" -o "${TARGET_DIR}/search/${file}" || echo "    (failed, skipping)"
done

echo "Downloading crossover files..."
for file in "${CROSSOVER_FILES[@]}"; do
    echo "  - crossover/${file}"
    curl -sL "${PYVRP_REPO}/pyvrp/cpp/crossover/${file}" -o "${TARGET_DIR}/crossover/${file}" || echo "    (failed, skipping)"
done

echo "Downloading diversity files..."
for file in "${DIVERSITY_FILES[@]}"; do
    echo "  - diversity/${file}"
    curl -sL "${PYVRP_REPO}/pyvrp/cpp/diversity/${file}" -o "${TARGET_DIR}/diversity/${file}" || echo "    (failed, skipping)"
done

echo "Downloading repair files..."
for file in "${REPAIR_FILES[@]}"; do
    echo "  - repair/${file}"
    curl -sL "${PYVRP_REPO}/pyvrp/cpp/repair/${file}" -o "${TARGET_DIR}/repair/${file}" || echo "    (failed, skipping)"
done

echo "Done! PyVRP C++ source vendored to ${TARGET_DIR}"
echo ""
echo "Files downloaded:"
find "${TARGET_DIR}" -type f \( -name "*.cpp" -o -name "*.h" \) | wc -l

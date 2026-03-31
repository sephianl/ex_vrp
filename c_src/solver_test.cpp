/**
 * Standalone solver test for running under valgrind.
 * Tests multiple scenarios: basic VRP, prize-collecting, SVGs, zones,
 * multi-trip, and combinations. Each test builds a ProblemData, runs
 * LocalSearch::search, and verifies the result.
 *
 * Build: make test-solver
 * Run:   valgrind --error-exitcode=1 ./solver_test
 */
#include "pyvrp/ProblemData.h"
#include "pyvrp/RandomNumberGenerator.h"
#include "pyvrp/Solution.h"
#include "pyvrp/search/Exchange.h"
#include "pyvrp/search/LocalSearch.h"
#include "pyvrp/search/PerturbationManager.h"
#include "pyvrp/search/RelocateWithDepot.h"
#include "pyvrp/search/SwapRoutes.h"
#include "pyvrp/search/SwapTails.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

using namespace pyvrp;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

struct TestLocalSearch
{
    std::unique_ptr<search::Exchange<1, 0>> exchange10;
    std::unique_ptr<search::Exchange<2, 0>> exchange20;
    std::unique_ptr<search::Exchange<1, 1>> exchange11;
    std::unique_ptr<search::Exchange<2, 1>> exchange21;
    std::unique_ptr<search::Exchange<2, 2>> exchange22;
    std::unique_ptr<search::SwapTails> swapTails;
    std::unique_ptr<search::RelocateWithDepot> relocateDepot;
    std::unique_ptr<search::SwapRoutes> swapRoutes;
    search::PerturbationParams perturbParams;
    search::PerturbationManager perturbManager;
    std::unique_ptr<search::LocalSearch> ls;

    TestLocalSearch(ProblemData const &pd,
                    search::SearchSpace::Neighbours const &neighbours)
        : perturbParams(1, 25), perturbManager(perturbParams)
    {
        ls = std::make_unique<search::LocalSearch>(
            pd, neighbours, perturbManager);

        exchange10 = std::make_unique<search::Exchange<1, 0>>(pd);
        exchange20 = std::make_unique<search::Exchange<2, 0>>(pd);
        exchange11 = std::make_unique<search::Exchange<1, 1>>(pd);
        exchange21 = std::make_unique<search::Exchange<2, 1>>(pd);
        exchange22 = std::make_unique<search::Exchange<2, 2>>(pd);
        ls->addNodeOperator(*exchange10);
        ls->addNodeOperator(*exchange20);
        ls->addNodeOperator(*exchange11);
        ls->addNodeOperator(*exchange21);
        ls->addNodeOperator(*exchange22);

        if (search::supports<search::SwapTails>(pd))
        {
            swapTails = std::make_unique<search::SwapTails>(pd);
            ls->addNodeOperator(*swapTails);
        }
        if (search::supports<search::RelocateWithDepot>(pd))
        {
            relocateDepot = std::make_unique<search::RelocateWithDepot>(pd);
            ls->addNodeOperator(*relocateDepot);
        }
        if (search::supports<search::SwapRoutes>(pd))
        {
            swapRoutes = std::make_unique<search::SwapRoutes>(pd);
            ls->addRouteOperator(*swapRoutes);
        }
    }
};

search::SearchSpace::Neighbours buildNeighbours(ProblemData const &pd,
                                                size_t k = 40)
{
    search::SearchSpace::Neighbours neighbours(pd.numLocations());
    k = std::min(k, pd.numLocations() - 1);

    for (size_t i = pd.numDepots(); i < pd.numLocations(); ++i)
    {
        auto const &distMat = pd.distanceMatrix(0);
        std::vector<std::pair<int64_t, size_t>> dists;
        for (size_t j = pd.numDepots(); j < pd.numLocations(); ++j)
        {
            if (i == j)
                continue;
            dists.emplace_back(distMat(i, j).get(), j);
        }
        std::sort(dists.begin(), dists.end());
        size_t actual_k = std::min(k, dists.size());
        for (size_t idx = 0; idx < actual_k; ++idx)
            neighbours[i].push_back(dists[idx].second);
    }
    return neighbours;
}

Matrix<Distance> makeDistMatrix(size_t n,
                                std::vector<std::pair<int64_t, int64_t>> coords)
{
    std::vector<Distance> flat;
    flat.reserve(n * n);
    for (size_t i = 0; i < n; ++i)
        for (size_t j = 0; j < n; ++j)
        {
            auto dx = coords[i].first - coords[j].first;
            auto dy = coords[i].second - coords[j].second;
            flat.push_back(
                Distance(static_cast<int64_t>(std::sqrt(dx * dx + dy * dy))));
        }
    return Matrix<Distance>(std::move(flat), n, n);
}

Matrix<Duration> makeDurMatrix(size_t n,
                               std::vector<std::pair<int64_t, int64_t>> coords)
{
    std::vector<Duration> flat;
    flat.reserve(n * n);
    for (size_t i = 0; i < n; ++i)
        for (size_t j = 0; j < n; ++j)
        {
            auto dx = coords[i].first - coords[j].first;
            auto dy = coords[i].second - coords[j].second;
            flat.push_back(
                Duration(static_cast<int64_t>(std::sqrt(dx * dx + dy * dy))));
        }
    return Matrix<Duration>(std::move(flat), n, n);
}

// Runs a single local search (no perturbation).
Solution solveEmpty(ProblemData const &pd)
{
    auto neighbours = buildNeighbours(pd);
    TestLocalSearch tls(pd, neighbours);

    CostEvaluator costEval(
        std::vector<double>(pd.numLoadDimensions(), 100000.0),
        100000.0,
        100000.0);

    std::vector<std::vector<size_t>> emptyRoutes;
    Solution emptySol(pd, emptyRoutes);
    return tls.ls->search(emptySol, costEval, 0);
}

// Runs operator() which includes perturbation + search + intensify loop.
// Then does a few more iterations to simulate ILS.
// Uses pointers + move-construction since Solution::operator= is private.
Solution solveWithPerturbation(ProblemData const &pd, int iterations = 5)
{
    auto neighbours = buildNeighbours(pd);
    TestLocalSearch tls(pd, neighbours);

    CostEvaluator costEval(
        std::vector<double>(pd.numLoadDimensions(), 100000.0),
        100000.0,
        100000.0);

    std::vector<std::vector<size_t>> emptyRoutes;
    Solution emptySol(pd, emptyRoutes);

    // First call: search (no perturbation on empty solution)
    auto sol
        = std::make_unique<Solution>(tls.ls->search(emptySol, costEval, 0));

    // Subsequent calls: operator() includes perturbation
    RandomNumberGenerator rng(42);
    for (int i = 0; i < iterations; ++i)
    {
        tls.ls->shuffle(rng);
        sol = std::make_unique<Solution>((*tls.ls)(*sol, costEval));
    }

    return Solution(std::move(*sol));
}

// ---------------------------------------------------------------------------
// Test cases
// ---------------------------------------------------------------------------

int passed = 0;
int failed = 0;

#define TEST(name)                                                             \
    printf("  %-60s", name);                                                   \
    fflush(stdout)

#define PASS()                                                                 \
    do                                                                         \
    {                                                                          \
        printf("PASS\n");                                                      \
        passed++;                                                              \
    } while (0)

void test_basic_vrp()
{
    TEST("basic VRP (20 clients, 3 vehicles)");

    size_t n = 21;  // 1 depot + 20 clients
    std::vector<std::pair<int64_t, int64_t>> coords;
    coords.push_back({0, 0});  // depot
    for (size_t i = 1; i < n; ++i)
        coords.push_back({static_cast<int64_t>((i * 7) % 100),
                          static_cast<int64_t>((i * 13) % 100)});

    std::vector<ProblemData::Client> clients;
    for (size_t i = 1; i < n; ++i)
        clients.emplace_back(coords[i].first,
                             coords[i].second,
                             std::vector<Load>{1},
                             std::vector<Load>{},
                             Duration(0),
                             Duration(0),
                             Duration(100000),
                             Duration(0),
                             Cost(0),
                             true,
                             std::nullopt,
                             "");

    std::vector<ProblemData::Depot> depots;
    depots.emplace_back(
        0, 0, Duration(0), Duration(100000), Duration(0), Cost(0), "");

    std::vector<ProblemData::VehicleType> vts;
    vts.emplace_back(3,
                     std::vector<Load>{20},
                     0,
                     0,
                     Cost(0),
                     Duration(0),
                     Duration(100000),
                     Duration(100000),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(0),
                     0,
                     std::nullopt,
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "");

    std::vector<Matrix<Distance>> distMats;
    distMats.push_back(makeDistMatrix(n, coords));
    std::vector<Matrix<Duration>> durMats;
    durMats.push_back(makeDurMatrix(n, coords));

    ProblemData pd(std::move(clients),
                   std::move(depots),
                   std::move(vts),
                   std::move(distMats),
                   std::move(durMats),
                   {},
                   {});

    auto result = solveEmpty(pd);
    assert(result.numClients() == 20);
    assert(result.isFeasible());
    PASS();
}

void test_prize_collecting()
{
    TEST("prize collecting (30 clients, 4 vehicles, optional)");

    size_t n = 31;
    std::vector<std::pair<int64_t, int64_t>> coords;
    coords.push_back({0, 0});
    for (size_t i = 1; i < n; ++i)
        coords.push_back({static_cast<int64_t>((i * 11) % 100),
                          static_cast<int64_t>((i * 17) % 100)});

    std::vector<ProblemData::Client> clients;
    for (size_t i = 1; i < n; ++i)
        clients.emplace_back(coords[i].first,
                             coords[i].second,
                             std::vector<Load>{1},
                             std::vector<Load>{},
                             Duration(0),
                             Duration(0),
                             Duration(100000),
                             Duration(0),
                             Cost(150000),
                             false,
                             std::nullopt,
                             "");

    std::vector<ProblemData::Depot> depots;
    depots.emplace_back(
        0, 0, Duration(0), Duration(100000), Duration(0), Cost(0), "");

    std::vector<ProblemData::VehicleType> vts;
    vts.emplace_back(4,
                     std::vector<Load>{20},
                     0,
                     0,
                     Cost(0),
                     Duration(0),
                     Duration(100000),
                     Duration(100000),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(0),
                     0,
                     std::nullopt,
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "");

    std::vector<Matrix<Distance>> distMats;
    distMats.push_back(makeDistMatrix(n, coords));
    std::vector<Matrix<Duration>> durMats;
    durMats.push_back(makeDurMatrix(n, coords));

    ProblemData pd(std::move(clients),
                   std::move(depots),
                   std::move(vts),
                   std::move(distMats),
                   std::move(durMats),
                   {},
                   {});

    auto result = solveEmpty(pd);
    assert(result.numClients() > 0);
    PASS();
}

void test_svg_small()
{
    TEST("SVG small (20 clients, 1 SVG pair)");

    size_t n = 21;
    std::vector<std::pair<int64_t, int64_t>> coords;
    coords.push_back({0, 0});
    for (size_t i = 1; i < n; ++i)
        coords.push_back({static_cast<int64_t>((i * 7) % 100),
                          static_cast<int64_t>((i * 13) % 100)});

    std::vector<ProblemData::Client> clients;
    for (size_t i = 1; i < n; ++i)
        clients.emplace_back(coords[i].first,
                             coords[i].second,
                             std::vector<Load>{1},
                             std::vector<Load>{},
                             Duration(0),
                             Duration(0),
                             Duration(100000),
                             Duration(0),
                             Cost(0),
                             true,
                             std::nullopt,
                             "");

    std::vector<ProblemData::Depot> depots;
    depots.emplace_back(
        0, 0, Duration(0), Duration(100000), Duration(0), Cost(0), "");

    std::vector<ProblemData::VehicleType> vts;
    vts.emplace_back(3,
                     std::vector<Load>{20},
                     0,
                     0,
                     Cost(0),
                     Duration(0),
                     Duration(100000),
                     Duration(100000),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(0),
                     0,
                     std::nullopt,
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "");

    std::vector<Matrix<Distance>> distMats;
    distMats.push_back(makeDistMatrix(n, coords));
    std::vector<Matrix<Duration>> durMats;
    durMats.push_back(makeDurMatrix(n, coords));

    // SVG: clients 3 and 10 must be on same vehicle
    std::vector<ProblemData::SameVehicleGroup> svgs;
    svgs.emplace_back(std::vector<size_t>{3, 10}, "test");

    ProblemData pd(std::move(clients),
                   std::move(depots),
                   std::move(vts),
                   std::move(distMats),
                   std::move(durMats),
                   {},
                   std::move(svgs));

    auto result = solveEmpty(pd);
    assert(result.numClients() == 20);
    PASS();
}

void test_svg_large()
{
    TEST("SVG large (80 clients, 3 SVG pairs)");

    size_t n = 81;
    std::vector<std::pair<int64_t, int64_t>> coords;
    coords.push_back({0, 0});
    for (size_t i = 1; i < n; ++i)
        coords.push_back({static_cast<int64_t>((i * 7) % 200),
                          static_cast<int64_t>((i * 13) % 200)});

    std::vector<ProblemData::Client> clients;
    for (size_t i = 1; i < n; ++i)
        clients.emplace_back(coords[i].first,
                             coords[i].second,
                             std::vector<Load>{1},
                             std::vector<Load>{},
                             Duration(0),
                             Duration(0),
                             Duration(100000),
                             Duration(0),
                             Cost(150000),
                             false,
                             std::nullopt,
                             "");

    std::vector<ProblemData::Depot> depots;
    depots.emplace_back(
        0, 0, Duration(0), Duration(100000), Duration(0), Cost(0), "");

    std::vector<ProblemData::VehicleType> vts;
    vts.emplace_back(8,
                     std::vector<Load>{50},
                     0,
                     0,
                     Cost(0),
                     Duration(0),
                     Duration(100000),
                     Duration(100000),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(0),
                     0,
                     std::nullopt,
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "");

    std::vector<Matrix<Distance>> distMats;
    distMats.push_back(makeDistMatrix(n, coords));
    std::vector<Matrix<Duration>> durMats;
    durMats.push_back(makeDurMatrix(n, coords));

    // 3 SVG pairs spread across the client range
    std::vector<ProblemData::SameVehicleGroup> svgs;
    svgs.emplace_back(std::vector<size_t>{3, 40}, "svg1");
    svgs.emplace_back(std::vector<size_t>{15, 60}, "svg2");
    svgs.emplace_back(std::vector<size_t>{25, 50, 75}, "svg3");

    ProblemData pd(std::move(clients),
                   std::move(depots),
                   std::move(vts),
                   std::move(distMats),
                   std::move(durMats),
                   {},
                   std::move(svgs));

    auto result = solveEmpty(pd);
    assert(result.numClients() > 0);
    PASS();
}

void test_zone_forbidden()
{
    TEST("zone forbidden (40 clients, 2 profiles, forbidden dests)");

    size_t n = 41;
    std::vector<std::pair<int64_t, int64_t>> coords;
    coords.push_back({0, 0});
    for (size_t i = 1; i < n; ++i)
        coords.push_back({static_cast<int64_t>((i * 7) % 100),
                          static_cast<int64_t>((i * 13) % 100)});

    std::vector<ProblemData::Client> clients;
    for (size_t i = 1; i < n; ++i)
        clients.emplace_back(coords[i].first,
                             coords[i].second,
                             std::vector<Load>{1},
                             std::vector<Load>{},
                             Duration(0),
                             Duration(0),
                             Duration(100000),
                             Duration(0),
                             Cost(150000),
                             false,
                             std::nullopt,
                             "");

    std::vector<ProblemData::Depot> depots;
    depots.emplace_back(
        0, 0, Duration(0), Duration(100000), Duration(0), Cost(0), "");

    // 2 vehicle types with different profiles
    std::vector<ProblemData::VehicleType> vts;
    vts.emplace_back(3,
                     std::vector<Load>{30},
                     0,
                     0,
                     Cost(0),
                     Duration(0),
                     Duration(100000),
                     Duration(100000),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(0),
                     0,
                     std::nullopt,  // profile 0
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "standard");
    vts.emplace_back(1,
                     std::vector<Load>{30},
                     0,
                     0,
                     Cost(0),
                     Duration(0),
                     Duration(100000),
                     Duration(100000),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(0),
                     1,
                     std::nullopt,  // profile 1
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "specialist");

    // Profile 0: clients 35-40 are forbidden (1 billion distance)
    // Profile 1: all reachable
    auto dist0 = makeDistMatrix(n, coords);
    auto dur0 = makeDurMatrix(n, coords);
    auto dist1 = makeDistMatrix(n, coords);
    auto dur1 = makeDurMatrix(n, coords);

    // Make clients 35-40 forbidden for profile 0
    // Access internal data via the matrix dimensions
    // Since Matrix doesn't have a setter, we rebuild with modified data
    {
        std::vector<Distance> flat;
        for (size_t i = 0; i < n; ++i)
            for (size_t j = 0; j < n; ++j)
            {
                if (j >= 35 && j < n && i != j)
                    flat.push_back(Distance(1000000000));
                else
                    flat.push_back(dist0(i, j));
            }
        dist0 = Matrix<Distance>(std::move(flat), n, n);
    }

    std::vector<Matrix<Distance>> distMats;
    distMats.push_back(std::move(dist0));
    distMats.push_back(std::move(dist1));
    std::vector<Matrix<Duration>> durMats;
    durMats.push_back(std::move(dur0));
    durMats.push_back(std::move(dur1));

    ProblemData pd(std::move(clients),
                   std::move(depots),
                   std::move(vts),
                   std::move(distMats),
                   std::move(durMats),
                   {},
                   {});

    auto result = solveEmpty(pd);
    assert(result.numClients() > 0);
    PASS();
}

void test_svg_with_zones()
{
    TEST("SVG + zones (60 clients, 2 profiles, 2 SVGs, forbidden)");

    size_t n = 61;
    std::vector<std::pair<int64_t, int64_t>> coords;
    coords.push_back({0, 0});
    for (size_t i = 1; i < n; ++i)
        coords.push_back({static_cast<int64_t>((i * 7) % 150),
                          static_cast<int64_t>((i * 13) % 150)});

    std::vector<ProblemData::Client> clients;
    for (size_t i = 1; i < n; ++i)
        clients.emplace_back(coords[i].first,
                             coords[i].second,
                             std::vector<Load>{1},
                             std::vector<Load>{},
                             Duration(300),
                             Duration(0),
                             Duration(100000),
                             Duration(0),
                             Cost(150000),
                             false,
                             std::nullopt,
                             "");

    std::vector<ProblemData::Depot> depots;
    depots.emplace_back(
        0, 0, Duration(0), Duration(100000), Duration(0), Cost(0), "");

    std::vector<ProblemData::VehicleType> vts;
    vts.emplace_back(5,
                     std::vector<Load>{30},
                     0,
                     0,
                     Cost(93000),
                     Duration(0),
                     Duration(100000),
                     Duration(28800),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(1),
                     0,
                     std::nullopt,
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "standard");
    vts.emplace_back(1,
                     std::vector<Load>{30},
                     0,
                     0,
                     Cost(93000),
                     Duration(0),
                     Duration(100000),
                     Duration(28800),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(1),
                     1,
                     std::nullopt,
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "zone_driver");

    auto dist0 = makeDistMatrix(n, coords);
    auto dur0 = makeDurMatrix(n, coords);
    auto dist1 = makeDistMatrix(n, coords);
    auto dur1 = makeDurMatrix(n, coords);

    // Forbidden clients 50-60 for profile 0
    {
        std::vector<Distance> flat;
        for (size_t i = 0; i < n; ++i)
            for (size_t j = 0; j < n; ++j)
            {
                if (j >= 50 && j < n && i != j)
                    flat.push_back(Distance(1000000000));
                else
                    flat.push_back(dist0(i, j));
            }
        dist0 = Matrix<Distance>(std::move(flat), n, n);
    }

    std::vector<Matrix<Distance>> distMats;
    distMats.push_back(std::move(dist0));
    distMats.push_back(std::move(dist1));
    std::vector<Matrix<Duration>> durMats;
    durMats.push_back(std::move(dur0));
    durMats.push_back(std::move(dur1));

    // SVGs: one pair in the forbidden zone, one in the open
    std::vector<ProblemData::SameVehicleGroup> svgs;
    svgs.emplace_back(std::vector<size_t>{52, 55}, "zone_svg");
    svgs.emplace_back(std::vector<size_t>{10, 30}, "normal_svg");

    ProblemData pd(std::move(clients),
                   std::move(depots),
                   std::move(vts),
                   std::move(distMats),
                   std::move(durMats),
                   {},
                   std::move(svgs));

    auto result = solveEmpty(pd);
    assert(result.numClients() > 0);
    PASS();
}

void test_multi_dim_capacity()
{
    TEST("multi-dim capacity (40 clients, 4 dims, 5 vehicles)");

    size_t n = 41;
    std::vector<std::pair<int64_t, int64_t>> coords;
    coords.push_back({0, 0});
    for (size_t i = 1; i < n; ++i)
        coords.push_back({static_cast<int64_t>((i * 7) % 100),
                          static_cast<int64_t>((i * 13) % 100)});

    std::vector<ProblemData::Client> clients;
    for (size_t i = 1; i < n; ++i)
        clients.emplace_back(coords[i].first,
                             coords[i].second,
                             std::vector<Load>{static_cast<int64_t>(i % 5 + 1),
                                               static_cast<int64_t>(i % 3),
                                               static_cast<int64_t>(i % 7),
                                               static_cast<int64_t>(i % 2)},
                             std::vector<Load>{},
                             Duration(0),
                             Duration(0),
                             Duration(100000),
                             Duration(0),
                             Cost(0),
                             true,
                             std::nullopt,
                             "");

    std::vector<ProblemData::Depot> depots;
    depots.emplace_back(
        0, 0, Duration(0), Duration(100000), Duration(0), Cost(0), "");

    std::vector<ProblemData::VehicleType> vts;
    vts.emplace_back(5,
                     std::vector<Load>{30, 20, 40, 10},
                     0,
                     0,
                     Cost(0),
                     Duration(0),
                     Duration(100000),
                     Duration(100000),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(0),
                     0,
                     std::nullopt,
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "");

    std::vector<Matrix<Distance>> distMats;
    distMats.push_back(makeDistMatrix(n, coords));
    std::vector<Matrix<Duration>> durMats;
    durMats.push_back(makeDurMatrix(n, coords));

    ProblemData pd(std::move(clients),
                   std::move(depots),
                   std::move(vts),
                   std::move(distMats),
                   std::move(durMats),
                   {},
                   {});

    auto result = solveEmpty(pd);
    assert(result.numClients() == 40);
    assert(result.isFeasible());
    PASS();
}

void test_tight_time_windows()
{
    TEST("tight time windows (30 clients, 2h windows, 4 vehicles)");

    size_t n = 31;
    std::vector<std::pair<int64_t, int64_t>> coords;
    coords.push_back({0, 0});
    for (size_t i = 1; i < n; ++i)
        coords.push_back({static_cast<int64_t>((i * 11) % 100),
                          static_cast<int64_t>((i * 17) % 100)});

    std::vector<ProblemData::Client> clients;
    for (size_t i = 1; i < n; ++i)
    {
        Duration twEarly(static_cast<int64_t>((i * 1000) % 20000));
        Duration twLate = twEarly + Duration(7200);  // 2h window
        clients.emplace_back(coords[i].first,
                             coords[i].second,
                             std::vector<Load>{1},
                             std::vector<Load>{},
                             Duration(300),
                             twEarly,
                             twLate,
                             Duration(0),
                             Cost(150000),
                             false,
                             std::nullopt,
                             "");
    }

    std::vector<ProblemData::Depot> depots;
    depots.emplace_back(
        0, 0, Duration(0), Duration(50000), Duration(0), Cost(0), "");

    std::vector<ProblemData::VehicleType> vts;
    vts.emplace_back(4,
                     std::vector<Load>{20},
                     0,
                     0,
                     Cost(0),
                     Duration(0),
                     Duration(50000),
                     Duration(50000),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(0),
                     0,
                     std::nullopt,
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "");

    std::vector<Matrix<Distance>> distMats;
    distMats.push_back(makeDistMatrix(n, coords));
    std::vector<Matrix<Duration>> durMats;
    durMats.push_back(makeDurMatrix(n, coords));

    ProblemData pd(std::move(clients),
                   std::move(depots),
                   std::move(vts),
                   std::move(distMats),
                   std::move(durMats),
                   {},
                   {});

    auto result = solveEmpty(pd);
    assert(result.numClients() > 0);
    PASS();
}

void test_perturbation_prize_collecting()
{
    TEST("perturbation + prize-collecting (ILS loop)");

    size_t n = 21;
    std::vector<std::pair<int64_t, int64_t>> coords;
    coords.push_back({0, 0});
    for (size_t i = 1; i < n; ++i)
        coords.push_back({static_cast<int64_t>((i * 11) % 100),
                          static_cast<int64_t>((i * 17) % 100)});

    std::vector<ProblemData::Client> clients;
    for (size_t i = 1; i < n; ++i)
    {
        bool required = (i <= 10);
        Cost prize = required ? Cost(0) : Cost(1);  // small prize for optional
        clients.emplace_back(coords[i].first,
                             coords[i].second,
                             std::vector<Load>{1},
                             std::vector<Load>{},
                             Duration(0),
                             Duration(0),
                             Duration(100000),
                             Duration(0),
                             prize,
                             required,
                             std::nullopt,
                             "");
    }

    std::vector<ProblemData::Depot> depots;
    depots.emplace_back(
        0, 0, Duration(0), Duration(100000), Duration(0), Cost(0), "");

    std::vector<ProblemData::VehicleType> vts;
    vts.emplace_back(3,
                     std::vector<Load>{20},
                     0,
                     0,
                     Cost(0),
                     Duration(0),
                     Duration(100000),
                     Duration(100000),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(0),
                     0,
                     std::nullopt,
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "");

    std::vector<Matrix<Distance>> distMats;
    distMats.push_back(makeDistMatrix(n, coords));
    std::vector<Matrix<Duration>> durMats;
    durMats.push_back(makeDurMatrix(n, coords));

    ProblemData pd(std::move(clients),
                   std::move(depots),
                   std::move(vts),
                   std::move(distMats),
                   std::move(durMats),
                   {},
                   {});

    // This exercises operator() with perturbation which force-inserts
    // optional clients. Before fix: null-pointer crash in
    // PerturbationManager when insert failed.
    auto result = solveWithPerturbation(pd, 10);
    assert(result.numClients() >= 10);  // at least required clients
    PASS();
}

void test_backhaul_like()
{
    TEST("backhaul-like (required clients, insert can fail)");

    // Simulates VRPB: all clients required, tight capacity forces insert
    // failures. Before fix: null-pointer crash in applyOptionalClientMoves
    // when solution_.insert returned false for required client.
    size_t n = 51;  // 1 depot + 50 clients
    std::vector<std::pair<int64_t, int64_t>> coords;
    coords.push_back({0, 0});
    for (size_t i = 1; i < n; ++i)
        coords.push_back({static_cast<int64_t>((i * 7) % 200),
                          static_cast<int64_t>((i * 13) % 200)});

    std::vector<ProblemData::Client> clients;
    for (size_t i = 1; i < n; ++i)
        clients.emplace_back(coords[i].first,
                             coords[i].second,
                             std::vector<Load>{3},
                             std::vector<Load>{},
                             Duration(0),
                             Duration(0),
                             Duration(100000),
                             Duration(0),
                             Cost(0),
                             true,
                             std::nullopt,
                             "");

    std::vector<ProblemData::Depot> depots;
    depots.emplace_back(
        0, 0, Duration(0), Duration(100000), Duration(0), Cost(0), "");

    // Tight capacity: 50 clients * 3 demand = 150 total, 3 vehicles * 20 = 60
    // This means not all clients can be placed, forcing insert failures.
    std::vector<ProblemData::VehicleType> vts;
    vts.emplace_back(3,
                     std::vector<Load>{20},
                     0,
                     0,
                     Cost(0),
                     Duration(0),
                     Duration(100000),
                     Duration(100000),
                     Distance(std::numeric_limits<int64_t>::max()),
                     Cost(1),
                     Cost(0),
                     0,
                     std::nullopt,
                     std::vector<Load>{},
                     std::vector<size_t>{},
                     0,
                     Duration(0),
                     Cost(0),
                     "");

    std::vector<Matrix<Distance>> distMats;
    distMats.push_back(makeDistMatrix(n, coords));
    std::vector<Matrix<Duration>> durMats;
    durMats.push_back(makeDurMatrix(n, coords));

    ProblemData pd(std::move(clients),
                   std::move(depots),
                   std::move(vts),
                   std::move(distMats),
                   std::move(durMats),
                   {},
                   {});

    // Use perturbation loop — this is where the crash occurred
    auto result = solveWithPerturbation(pd, 10);
    assert(result.numClients() > 0);
    PASS();
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main()
{
    printf("ExVrp Solver Memory Tests (run under valgrind)\n");
    printf("==============================================\n\n");

    test_basic_vrp();
    test_prize_collecting();
    test_svg_small();
    test_svg_large();
    test_zone_forbidden();
    test_svg_with_zones();
    test_multi_dim_capacity();
    test_tight_time_windows();
    test_perturbation_prize_collecting();
    test_backhaul_like();

    printf("\n%d passed, %d failed\n", passed, failed);
    return failed > 0 ? 1 : 0;
}

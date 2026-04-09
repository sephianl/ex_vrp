/**
 * Standalone test to reproduce SVG crash under valgrind/MSan.
 * Build: g++ -std=c++20 -O2 -g -Ic_src -Ic_src/pyvrp -o svg_crash_test
 * c_src/svg_crash_test.cpp c_src/obj/pyvrp/*.o c_src/obj/pyvrp/search/*.o Run:
 * valgrind ./svg_crash_test
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

#include <cstdio>
#include <vector>

using namespace pyvrp;

int main()
{
    // Build a problem with 55 clients + 1 SVG (reproduces crash)
    constexpr size_t NUM_CLIENTS = 55;
    constexpr size_t NUM_VEHICLES = 6;

    std::vector<ProblemData::Client> clients;
    for (size_t i = 0; i < NUM_CLIENTS; ++i)
    {
        clients.emplace_back(static_cast<int64_t>((i * 7) % 100),   // x
                             static_cast<int64_t>((i * 13) % 100),  // y
                             std::vector<Load>{1},                  // delivery
                             std::vector<Load>{},                   // pickup
                             Duration(0),       // service_duration
                             Duration(0),       // tw_early
                             Duration(100000),  // tw_late
                             Duration(0),       // release_time
                             Cost(150000),      // prize
                             false,             // required
                             std::nullopt,      // group
                             "");               // name
    }

    std::vector<ProblemData::Depot> depots;
    depots.emplace_back(
        0, 0, Duration(0), Duration(100000), Duration(0), Cost(0), "");

    std::vector<ProblemData::VehicleType> vehicleTypes;
    vehicleTypes.emplace_back(
        NUM_VEHICLES,                                   // numAvailable
        std::vector<Load>{50},                          // capacity
        0,                                              // startDepot
        0,                                              // endDepot
        Cost(0),                                        // fixedCost
        Duration(0),                                    // twEarly
        Duration(100000),                               // twLate
        Duration(100000),                               // shiftDuration
        Distance(std::numeric_limits<int64_t>::max()),  // maxDistance
        Cost(1),                                        // unitDistanceCost
        Cost(0),                                        // unitDurationCost
        0,                                              // profile
        std::nullopt,                                   // startLate
        std::vector<Load>{},                            // initialLoad
        std::vector<size_t>{},                          // reloadDepots
        0,                                              // maxReloads
        Duration(0),                                    // maxOvertime
        Cost(0),                                        // unitOvertimeCost
        "");                                            // name

    // Distance/duration matrices (Euclidean from coords)
    size_t numLocs = 1 + NUM_CLIENTS;  // 1 depot + clients
    std::vector<std::vector<int64_t>> distData(
        numLocs, std::vector<int64_t>(numLocs, 0));
    for (size_t i = 0; i < numLocs; ++i)
    {
        int64_t xi = (i == 0) ? 0 : static_cast<int64_t>((i * 7) % 100);
        int64_t yi = (i == 0) ? 0 : static_cast<int64_t>((i * 13) % 100);
        for (size_t j = 0; j < numLocs; ++j)
        {
            int64_t xj = (j == 0) ? 0 : static_cast<int64_t>((j * 7) % 100);
            int64_t yj = (j == 0) ? 0 : static_cast<int64_t>((j * 13) % 100);
            int64_t dx = xi - xj;
            int64_t dy = yi - yj;
            distData[i][j] = static_cast<int64_t>(std::sqrt(dx * dx + dy * dy));
        }
    }

    std::vector<Matrix<Distance>> distMatrices;
    {
        std::vector<Distance> flat;
        for (auto &row : distData)
            for (auto v : row)
                flat.push_back(Distance(v));
        distMatrices.push_back(
            Matrix<Distance>(std::move(flat), numLocs, numLocs));
    }

    std::vector<Matrix<Duration>> durMatrices;
    {
        std::vector<Duration> flat;
        for (auto &row : distData)
            for (auto v : row)
                flat.push_back(Duration(v));
        durMatrices.push_back(
            Matrix<Duration>(std::move(flat), numLocs, numLocs));
    }

    // Same-vehicle group: clients 3 and 10 (location indices 3 and 10,
    // since depot is 0 and clients start at 1)
    // Wait: client indices in SVG are location indices.
    // Client i (0-based) has location index i + numDepots = i + 1
    std::vector<ProblemData::SameVehicleGroup> svgs;
    svgs.emplace_back(std::vector<size_t>{3, 10}, "test_svg");

    printf("Building ProblemData: %zu clients, %zu depots, %zu SVGs\n",
           clients.size(),
           depots.size(),
           svgs.size());

    ProblemData pd(std::move(clients),
                   std::move(depots),
                   std::move(vehicleTypes),
                   std::move(distMatrices),
                   std::move(durMatrices),
                   std::vector<ProblemData::ClientGroup>{},
                   std::move(svgs));

    printf("ProblemData created: %zu locations, %zu vehicles\n",
           pd.numLocations(),
           pd.numVehicles());

    // Build neighbourhood
    size_t k = std::min<size_t>(40, pd.numLocations() - 1);
    std::vector<std::vector<size_t>> neighbours(pd.numLocations());
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

    // Create perturbation manager + local search
    search::PerturbationParams perturbParams(1, 25);
    search::PerturbationManager perturbManager(perturbParams);
    search::LocalSearch ls(pd, neighbours, perturbManager);

    // Add operators
    search::Exchange<1, 0> exchange10(pd);
    search::Exchange<2, 0> exchange20(pd);
    search::Exchange<1, 1> exchange11(pd);
    search::Exchange<2, 1> exchange21(pd);
    search::Exchange<2, 2> exchange22(pd);
    ls.addNodeOperator(exchange10);
    ls.addNodeOperator(exchange20);
    ls.addNodeOperator(exchange11);
    ls.addNodeOperator(exchange21);
    ls.addNodeOperator(exchange22);

    // Keep operators alive for the lifetime of ls
    std::unique_ptr<search::SwapTails> swapTails;
    std::unique_ptr<search::SwapRoutes> swapRoutes;

    if (search::supports<search::SwapTails>(pd))
    {
        swapTails = std::make_unique<search::SwapTails>(pd);
        ls.addNodeOperator(*swapTails);
    }

    if (search::supports<search::SwapRoutes>(pd))
    {
        swapRoutes = std::make_unique<search::SwapRoutes>(pd);
        ls.addRouteOperator(*swapRoutes);
    }

    // Create cost evaluator with max penalties
    CostEvaluator costEval(std::vector<double>(1, 100000.0),  // load penalties
                           100000.0,                          // tw penalty
                           100000.0);                         // dist penalty

    // Create empty solution and run search
    printf("Creating empty solution...\n");
    std::vector<std::vector<size_t>> emptyRoutes;
    Solution emptySol(pd, emptyRoutes);

    printf(
        "Running LocalSearch::search (this is where the crash happens)...\n");
    Solution result = ls.search(emptySol, costEval, 0);

    printf("SUCCESS! %zu clients planned, feasible=%d\n",
           result.numClients(),
           result.isFeasible());

    return 0;
}

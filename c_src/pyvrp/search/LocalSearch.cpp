#include "LocalSearch.h"
#include "DynamicBitset.h"
#include "Measure.h"
#include "Trip.h"
#include "primitives.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstring>
#include <limits>
#include <numeric>

using pyvrp::Solution;
using pyvrp::search::BinaryOperator;
using pyvrp::search::LocalSearch;
using pyvrp::search::SearchSpace;
using pyvrp::search::UnaryOperator;

pyvrp::Solution LocalSearch::operator()(pyvrp::Solution const &solution,
                                        CostEvaluator const &costEvaluator,
                                        bool exhaustive,
                                        int64_t timeout_ms)
{
    loadSolution(solution);

    if (!exhaustive)
        perturbationManager_.perturb(solution_, searchSpace_, costEvaluator);

    markMissingAsPromising(costEvaluator);

    // Set up timeout tracking.  Always apply a safety deadline to
    // prevent infinite loops caused by oscillating moves (e.g.
    // forbidden-window cost evaluation inaccuracies in multi-trip
    // instances).  The default of 5 seconds is generous — normal
    // invocations complete in < 5 ms.
    static constexpr int64_t SAFETY_TIMEOUT_MS = 5000;
    has_timeout_ = true;
    timeout_deadline_ = std::chrono::steady_clock::now()
                        + std::chrono::milliseconds(
                            timeout_ms > 0 ? timeout_ms : SAFETY_TIMEOUT_MS);

    static constexpr int MAX_OUTER_ITERS = 15;
    for (int outerIter = 0; outerIter < MAX_OUTER_ITERS; ++outerIter)
    {
        search(costEvaluator);

        if (has_timeout_
            && std::chrono::steady_clock::now() >= timeout_deadline_)
            break;

        auto const numUpdates = numUpdates_;

        intensify(costEvaluator);

        if (has_timeout_
            && std::chrono::steady_clock::now() >= timeout_deadline_)
            break;

        if (numUpdates_ == numUpdates)
            break;
    }

    improveWithMultiTrip(costEvaluator);

    stripForbiddenWindowViolations();

    improveWithMultiTrip(costEvaluator, true);

    stripInfeasibleForbiddenWindowClients();

    return solution_.unload();
}

pyvrp::Solution LocalSearch::search(pyvrp::Solution const &solution,
                                    CostEvaluator const &costEvaluator,
                                    int64_t timeout_ms)
{
    loadSolution(solution);

    if (timeout_ms > 0)
    {
        has_timeout_ = true;
        timeout_deadline_ = std::chrono::steady_clock::now()
                            + std::chrono::milliseconds(timeout_ms);
    }
    else
    {
        has_timeout_ = false;
    }

    insertConstrainedFirst(costEvaluator);

    search(costEvaluator);

    repairForbiddenWindowRoutes(costEvaluator);

    improveWithMultiTrip(costEvaluator);

    stripForbiddenWindowViolations();

    improveWithMultiTrip(costEvaluator, true);

    stripInfeasibleForbiddenWindowClients();

    return solution_.unload();
}

void LocalSearch::search(CostEvaluator const &costEvaluator)
{
    if (binaryOps.empty() && unaryOps.empty())
        return;

    markMissingAsPromising(costEvaluator);

    searchCompleted_ = false;
    for (int step = 0; !searchCompleted_ && step < 15; ++step)
    {
        if (has_timeout_
            && std::chrono::steady_clock::now() >= timeout_deadline_)
            return;

        searchCompleted_ = true;

        for (auto const uClient : searchSpace_.clientOrder())
        {
            if (!searchSpace_.isPromising(uClient))
                continue;

            auto *U = &solution_.nodes[uClient];

            auto const lastTested = lastTestedNodes[U->client()];
            lastTestedNodes[U->client()] = numUpdates_;

            applyUnaryOps(U, costEvaluator);

            bool shouldTest = (lastTested == -1);
            if (!shouldTest && U->route())
                shouldTest = (lastUpdated[U->route()->idx()] > lastTested);

            if (shouldTest)
                applyOptionalClientMoves(U, costEvaluator);

            applyGroupMoves(U, costEvaluator);

            if (!U->route())
                continue;

            applySameVehicleRepair(U, costEvaluator);

            applyDepotRemovalMove(p(U), costEvaluator);
            applyDepotRemovalMove(n(U), costEvaluator);

            for (auto const vClient : searchSpace_.neighboursOf(U->client()))
            {
                auto *V = &solution_.nodes[vClient];

                if (!V->route())
                    continue;

                if (lastUpdated[U->route()->idx()] > lastTested
                    || lastUpdated[V->route()->idx()] > lastTested)
                {
                    if (applyBinaryOps(U, V, costEvaluator))
                        continue;

                    if (p(V)->isStartDepot()
                        && applyBinaryOps(U, p(V), costEvaluator))
                        continue;
                }
            }

            if (step > 0)
                applyEmptyRouteMoves(U, costEvaluator);
        }
    }
}

void LocalSearch::intensify(CostEvaluator const &costEvaluator)
{
    if (!swapStar_)
        return;

    swapStar_->init();

    static constexpr int MAX_INTENSIFY_STEPS = 15;
    int intensifyStep = 0;

    searchCompleted_ = false;
    while (!searchCompleted_ && intensifyStep++ < MAX_INTENSIFY_STEPS)
    {
        if (has_timeout_
            && std::chrono::steady_clock::now() >= timeout_deadline_)
            return;

        searchCompleted_ = true;

        for (auto const rU : searchSpace_.routeOrder())
        {
            auto *U = &solution_.routes[rU];
            assert(U->idx() == rU);

            if (U->empty())
                continue;

            auto const lastTested = lastTestedRoutes[U->idx()];
            lastTestedRoutes[U->idx()] = numUpdates_;

            for (size_t rV = U->idx() + 1; rV != solution_.routes.size(); ++rV)
            {
                auto *V = &solution_.routes[rV];
                assert(V->idx() == rV);

                if (V->empty())
                    continue;

                if (lastUpdated[U->idx()] > lastTested
                    || lastUpdated[V->idx()] > lastTested)
                {
                    auto const deltaCost
                        = swapStar_->evaluate(U, V, costEvaluator);
                    if (deltaCost < 0)
                    {
                        swapStar_->apply(U, V);
                        update(U, V);
                        swapStar_->update(U);
                        swapStar_->update(V);
                    }
                }
            }
        }
    }
}

void LocalSearch::shuffle(RandomNumberGenerator &rng)
{
    perturbationManager_.shuffle(rng);
    searchSpace_.shuffle(rng);

    rng.shuffle(unaryOps.begin(), unaryOps.end());
    rng.shuffle(binaryOps.begin(), binaryOps.end());
}

bool LocalSearch::isHardToPlace(Route::Node const *U) const
{
    if (!U->route() || U->isDepot())
        return false;

    // Only meaningful when there are multiple profiles (zone restrictions).
    // With <= 2 profiles every client is equally restricted, so none are
    // "hard to place".
    if (data.numProfiles() <= 2)
        return false;

    auto const client = U->client();

    // Count how many distinct profiles can reach this client
    size_t reachableProfiles = 0;
    for (size_t p = 0; p < data.numProfiles(); ++p)
    {
        auto const &distMatrix = data.distanceMatrix(p);
        // Check from any depot (use first depot as proxy)
        if (distMatrix(0, client) < 1'000'000'000)
            reachableProfiles++;
    }

    // A client reachable from very few profiles (relative to total) is
    // hard to place — protect it from removal.
    return reachableProfiles <= 2;
}

bool LocalSearch::wouldViolateForbidden(Route::Node const *U,
                                        Route const *targetRoute) const
{
    if (!targetRoute || U->isDepot())
        return false;

    auto const profile = data.vehicleType(targetRoute->vehicleType()).profile;
    auto const &distMatrix = data.distanceMatrix(profile);
    auto const startDepot
        = data.vehicleType(targetRoute->vehicleType()).startDepot;
    return distMatrix(startDepot, U->client()) >= 1'000'000'000;
}

bool LocalSearch::wouldViolateSameVehicle(Route::Node const *U,
                                          Route const *targetRoute) const
{
    auto const &groups = clientToSameVehicleGroups_[U->client()];
    if (groups.empty())
        return false;

    auto const *currentRoute = U->route();

    if (!currentRoute || currentRoute == targetRoute)
        return false;

    if (targetRoute)
    {
        auto const *currentName
            = data.vehicleType(currentRoute->vehicleType()).name;
        auto const *targetName
            = data.vehicleType(targetRoute->vehicleType()).name;

        if (currentName && targetName && currentName[0] != '\0'
            && std::strcmp(currentName, targetName) == 0)
            return false;
    }

    for (auto const groupIdx : groups)
    {
        auto const &group = data.sameVehicleGroup(groupIdx);

        for (auto const otherClient : group)
        {
            if (otherClient == U->client())
                continue;

            auto const *otherNode = &solution_.nodes[otherClient];
            if (!otherNode->route())
                continue;  // Partner not placed yet, no constraint

            // If partner is on the target route, moving U there is good
            // (brings them together).
            if (otherNode->route() == targetRoute)
                return false;

            // If partner is on U's current route, moving U away would
            // split them — only allow if the target route has another
            // partner already (for multi-member groups).
            if (otherNode->route() == currentRoute)
                return true;
        }
    }

    return false;
}

void LocalSearch::applyUnaryOps(Route::Node *U,
                                CostEvaluator const &costEvaluator)
{
    for (auto *op : unaryOps)
    {
        auto [deltaCost, shouldApply] = op->evaluate(U, costEvaluator);
        if (shouldApply)
        {
            auto *rBefore = U->route();
            if (rBefore)
                searchSpace_.markPromising(U);

            op->apply(U);

            auto *rAfter = U->route();
            if (rBefore)
                update(rBefore, rAfter ? rAfter : rBefore);
            else if (rAfter)
            {
                update(rAfter, rAfter);
                searchSpace_.markPromising(U);
            }
        }
    }

    if (!U->route())
    {
        ProblemData::Client const &uData
            = data.client(U->client() - data.numDepots());
        if (!uData.required && !uData.group
            && solution_.insert(U, searchSpace_, costEvaluator, false))
        {
            update(U->route(), U->route());
            searchSpace_.markPromising(U);
        }
    }
}

bool LocalSearch::applyBinaryOps(Route::Node *U,
                                 Route::Node *V,
                                 CostEvaluator const &costEvaluator)
{
    auto *rU = U->route();
    auto *rV = V->route();

    if (rU && rU != rV)
    {
        if (wouldViolateSameVehicle(U, rV) || wouldViolateSameVehicle(V, rU))
            return false;

        auto const *nU = n(U);
        auto const *nV = n(V);
        if (!nU->isEndDepot() && !nU->isDepot()
            && wouldViolateSameVehicle(nU, rV))
            return false;
        if (!nV->isEndDepot() && !nV->isDepot()
            && wouldViolateSameVehicle(nV, rU))
            return false;

        if (wouldViolateForbidden(U, rV) || wouldViolateForbidden(V, rU))
            return false;
    }

    for (auto *op : binaryOps)
    {
        auto [deltaCost, shouldApply] = op->evaluate(U, V, costEvaluator);
        if (shouldApply)
        {
            // For operators that swap entire tails (SwapTails/2-OPT*),
            // the per-client SVG check above is insufficient — we must
            // verify that no SVG group gets split by the tail swap.
            if (rU != rV && op->affectsEntireTail()
                && wouldTailSwapSplitSVG(U, V))
                continue;

            [[maybe_unused]] auto const costBefore
                = rU ? costEvaluator.penalisedCost(*rU)
                           + Cost(rU != rV) * costEvaluator.penalisedCost(*rV)
                     : costEvaluator.penalisedCost(*rV);

            if (rU)
                searchSpace_.markPromising(U);
            searchSpace_.markPromising(V);

            op->apply(U, V);
            update(rU, rV);

            [[maybe_unused]] auto const costAfter
                = rU ? costEvaluator.penalisedCost(*rU)
                           + Cost(rU != rV) * costEvaluator.penalisedCost(*rV)
                     : costEvaluator.penalisedCost(*rV);

            assert(!rU || rU->hasForbiddenWindows()
                   || (rU != rV && rV->hasForbiddenWindows())
                   || costAfter == costBefore + deltaCost);

            return true;
        }
    }

    return false;
}

void LocalSearch::applySameVehicleRepair(Route::Node *U,
                                         CostEvaluator const &costEvaluator)
{
    auto const &groups = clientToSameVehicleGroups_[U->client()];
    if (groups.empty() || !U->route())
        return;

    for (auto const groupIdx : groups)
    {
        auto const &group = data.sameVehicleGroup(groupIdx);
        for (auto const otherClient : group)
        {
            if (otherClient == U->client())
                continue;

            auto *V = &solution_.nodes[otherClient];
            if (!V->route() || V->route() == U->route())
                continue;

            {
                auto const *uName
                    = data.vehicleType(U->route()->vehicleType()).name;
                auto const *vName
                    = data.vehicleType(V->route()->vehicleType()).name;
                if (uName && vName && uName[0] != '\0'
                    && std::strcmp(uName, vName) == 0)
                    continue;
            }

            auto *rU = U->route();
            auto *rV = V->route();

            if (wouldViolateForbidden(U, rV))
                continue;

            Cost remCost = removeCost(U, data, costEvaluator);

            Cost bestIns = std::numeric_limits<Cost>::max();
            Route::Node *bestPos = nullptr;
            for (size_t idx = 0; idx + 1 < rV->size(); ++idx)
            {
                auto *pos = rV->operator[](idx);
                auto cost = insertCost(U, pos, data, costEvaluator);
                if (cost < bestIns)
                {
                    bestIns = cost;
                    bestPos = pos;
                }
            }

            if (!bestPos)
                continue;

            Cost totalDelta = remCost + bestIns - Cost(500'000);
            if (totalDelta < 0)
            {
                searchSpace_.markPromising(U);
                rU->remove(U->idx());
                update(rU, rU);

                rV->insert(bestPos->idx() + 1, U);
                update(rV, rV);
                searchSpace_.markPromising(U);
                return;
            }
        }
    }
}

bool LocalSearch::wouldTailSwapSplitSVG(Route::Node const *U,
                                        Route::Node const *V) const
{
    auto const *rU = U->route();
    auto const *rV = V->route();

    for (auto const *node = n(U); !node->isEndDepot(); node = n(node))
    {
        if (node->isDepot())
            continue;

        for (auto const groupIdx : clientToSameVehicleGroups_[node->client()])
        {
            for (auto const partner : data.sameVehicleGroup(groupIdx))
            {
                if (partner == node->client())
                    continue;
                auto const *pNode = &solution_.nodes[partner];
                if (pNode->route() == rU && pNode->idx() <= U->idx())
                    return true;
            }
        }
    }

    for (auto const *node = n(V); !node->isEndDepot(); node = n(node))
    {
        if (node->isDepot())
            continue;

        for (auto const groupIdx : clientToSameVehicleGroups_[node->client()])
        {
            for (auto const partner : data.sameVehicleGroup(groupIdx))
            {
                if (partner == node->client())
                    continue;
                auto const *pNode = &solution_.nodes[partner];
                if (pNode->route() == rV && pNode->idx() <= V->idx())
                    return true;
            }
        }
    }

    return false;
}

void LocalSearch::applyOptionalClientMoves(Route::Node *U,
                                           CostEvaluator const &costEvaluator)
{
    ProblemData::Client const &uData
        = data.client(U->client() - data.numDepots());

    if (uData.required && !U->route())
    {
        if (solution_.insert(U, searchSpace_, costEvaluator, true))
        {
            update(U->route(), U->route());
            searchSpace_.markPromising(U);
        }
    }

    if (uData.required || uData.group)
        return;

    if (!wouldViolateSameVehicle(U, nullptr) && !isHardToPlace(U)
        && removeCost(U, data, costEvaluator) < 0)
    {
        searchSpace_.markPromising(U);
        auto *route = U->route();
        auto const &vt = data.vehicleType(route->vehicleType());

        route->remove(U->idx());
        update(route, route);

        if (!vt.forbiddenWindows.empty())
            return;
    }

    if (U->route())
        return;

    if (solution_.insert(U, searchSpace_, costEvaluator, false))
    {
        update(U->route(), U->route());
        searchSpace_.markPromising(U);
        return;
    }

    for (auto const vClient : searchSpace_.neighboursOf(U->client()))
    {
        auto *V = &solution_.nodes[vClient];
        auto *route = V->route();

        if (!route)
            continue;

        ProblemData::Client const &vData
            = data.client(V->client() - data.numDepots());

        if (!vData.required && !wouldViolateSameVehicle(V, nullptr)
            && inplaceCost(U, V, data, costEvaluator) < 0)
        {
            searchSpace_.markPromising(V);
            auto const idx = V->idx();
            route->remove(idx);
            route->insert(idx, U);
            update(route, route);
            searchSpace_.markPromising(U);
            return;
        }
    }
}

void LocalSearch::applyGroupMoves(Route::Node *U,
                                  CostEvaluator const &costEvaluator)
{
    ProblemData::Client const &uData
        = data.client(U->client() - data.numDepots());

    if (!uData.group)
        return;

    auto const &group = data.group(*uData.group);
    assert(group.mutuallyExclusive);

    std::vector<size_t> inSol;
    auto const pred
        = [&](auto client) { return solution_.nodes[client].route(); };
    std::copy_if(group.begin(), group.end(), std::back_inserter(inSol), pred);

    if (inSol.empty())
    {
        auto const required = group.required;
        if (solution_.insert(U, searchSpace_, costEvaluator, required))
        {
            update(U->route(), U->route());
            searchSpace_.markPromising(U);
        }

        return;
    }

    std::vector<Cost> costs;
    for (auto const client : inSol)
    {
        auto cost = removeCost(&solution_.nodes[client], data, costEvaluator);
        costs.push_back(cost);
    }

    std::vector<size_t> range(inSol.size());
    std::iota(range.begin(), range.end(), 0);
    std::sort(range.begin(),
              range.end(),
              [&costs](auto idx1, auto idx2)
              { return costs[idx1] < costs[idx2]; });

    for (auto idx = range.begin(); idx != range.end() - 1; ++idx)
    {
        auto const client = inSol[*idx];
        auto const &node = solution_.nodes[client];
        auto *route = node.route();

        searchSpace_.markPromising(&node);
        route->remove(node.idx());
        update(route, route);
    }

    auto *V = &solution_.nodes[inSol[range.back()]];
    if (U != V && inplaceCost(U, V, data, costEvaluator) < 0)
    {
        auto *route = V->route();
        auto const idx = V->idx();
        route->remove(idx);
        route->insert(idx, U);
        update(route, route);
        searchSpace_.markPromising(U);
    }
}

void LocalSearch::applyDepotRemovalMove(Route::Node *U,
                                        CostEvaluator const &costEvaluator)
{
    if (!U->isReloadDepot())
        return;

    auto const &vehType = data.vehicleType(U->route()->vehicleType());
    if (!vehType.forbiddenWindows.empty())
        return;

    if (removeCost(U, data, costEvaluator) <= 0)
    {
        searchSpace_.markPromising(U);
        auto *route = U->route();
        route->remove(U->idx());
        update(route, route);
    }
}

void LocalSearch::applyEmptyRouteMoves(Route::Node *U,
                                       CostEvaluator const &costEvaluator)
{
    assert(U->route());

    for (auto const &[vehType, offset] : searchSpace_.vehTypeOrder())
    {
        auto const begin = solution_.routes.begin() + offset;
        auto const end = begin + data.vehicleType(vehType).numAvailable;
        auto const pred = [](auto const &route) { return route.empty(); };
        auto empty = std::find_if(begin, end, pred);

        if (empty != end && applyBinaryOps(U, (*empty)[0], costEvaluator))
            break;
    }
}

void LocalSearch::insertConstrainedFirst(CostEvaluator const &costEvaluator)
{
    for (size_t groupIdx = 0; groupIdx < data.numSameVehicleGroups();
         ++groupIdx)
    {
        auto const &group = data.sameVehicleGroup(groupIdx);

        bool anyPlaced = false;
        for (auto const client : group)
            if (solution_.nodes[client].route())
                anyPlaced = true;
        if (anyPlaced)
            continue;

        for (auto &route : solution_.routes)
        {
            auto const profile = data.vehicleType(route.vehicleType()).profile;
            auto const &distMatrix = data.distanceMatrix(profile);
            auto const startDepot
                = data.vehicleType(route.vehicleType()).startDepot;

            bool allReachable = true;
            for (auto const client : group)
            {
                if (distMatrix(startDepot, client) >= 1'000'000'000)
                {
                    allReachable = false;
                    break;
                }
            }

            if (!allReachable)
                continue;

            auto const &vehType = data.vehicleType(route.vehicleType());
            Duration availableTime = vehType.twLate - vehType.twEarly;
            for (auto const &[fStart, fEnd] : vehType.forbiddenWindows)
                availableTime -= (fEnd - fStart);

            Duration totalService = 0;
            for (auto const client : group)
            {
                ProblemData::Client const &cl = data.location(client);
                totalService += cl.serviceDuration;
            }

            if (totalService > availableTime)
                continue;

            for (auto const client : group)
            {
                auto *U = &solution_.nodes[client];
                auto const insertIdx = route.size() - 1;
                route.insert(insertIdx, U);
            }
            route.update();
            break;
        }
    }

    std::vector<std::pair<size_t, size_t>> clientReach;
    for (auto client = data.numDepots(); client != data.numLocations();
         ++client)
    {
        if (solution_.nodes[client].route())
            continue;

        size_t reachable = 0;
        for (auto const &route : solution_.routes)
        {
            auto const profile = data.vehicleType(route.vehicleType()).profile;
            auto const &distMatrix = data.distanceMatrix(profile);
            auto const startDepot
                = data.vehicleType(route.vehicleType()).startDepot;
            if (distMatrix(startDepot, client) < 1'000'000'000)
                reachable++;
        }

        if (reachable > 0 && reachable < solution_.routes.size())
            clientReach.emplace_back(reachable, client);
    }

    std::sort(clientReach.begin(), clientReach.end());

    for (auto const &[reach, client] : clientReach)
    {
        auto *U = &solution_.nodes[client];
        if (U->route())
            continue;

        if (solution_.insert(U, searchSpace_, costEvaluator, true))
        {
            update(U->route(), U->route());
            searchSpace_.markPromising(U);
        }
    }
}

void LocalSearch::markMissingAsPromising(
    [[maybe_unused]] CostEvaluator const &costEvaluator)
{
    for (auto client = data.numDepots(); client != data.numLocations();
         ++client)
    {
        if (solution_.nodes[client].route())
            continue;

        ProblemData::Client const &clientData
            = data.client(client - data.numDepots());

        if (clientData.required)
        {
            searchSpace_.markPromising(client);
            continue;
        }

        if (clientData.prize > 0)
        {
            searchSpace_.markPromising(client);
            continue;
        }

        if (clientData.group)
        {
            auto const &group = data.group(clientData.group.value());
            if (group.required && group.clients().front() == client)
            {
                searchSpace_.markPromising(client);
            }
            continue;
        }
    }
}

void LocalSearch::repairForbiddenWindowRoutes(
    [[maybe_unused]] CostEvaluator const &costEvaluator)
{
    for (auto &route : solution_.routes)
    {
        if (route.empty() || route.timeWarp() == 0)
            continue;

        auto const &vehType = data.vehicleType(route.vehicleType());
        if (vehType.forbiddenWindows.empty() || vehType.reloadDepots.empty())
            continue;
        if (route.numTrips() >= route.maxTrips())
            continue;

        auto const fStart = vehType.forbiddenWindows[0].first;
        auto const &durations = data.durationMatrix(vehType.profile);

        Duration now = vehType.twEarly;
        std::vector<size_t> lateClients;

        for (size_t idx = 0; idx < route.size(); ++idx)
        {
            auto *node = route[idx];
            if (idx > 0)
            {
                auto const prevLoc = route[idx - 1]->client();
                now += durations(prevLoc, node->client());
            }

            if (node->isDepot() || node->isReloadDepot())
                continue;

            ProblemData::Client const &cl = data.location(node->client());
            auto const wait = cl.twEarly > now ? cl.twEarly - now : Duration(0);
            auto const serviceEnd = now + wait + cl.serviceDuration;

            if (serviceEnd > fStart)
                lateClients.push_back(node->client());

            now = serviceEnd;
        }

        if (lateClients.empty())
            continue;

        for (auto it = lateClients.rbegin(); it != lateClients.rend(); ++it)
        {
            auto *U = &solution_.nodes[*it];
            if (!U->route())
                continue;
            U->route()->remove(U->idx());
        }
        route.update();

        Duration latestFWEnd = 0;
        for (auto const &[fStart, fEnd] : vehType.forbiddenWindows)
            if (fEnd > latestFWEnd)
                latestFWEnd = fEnd;

        Duration remainingTime = vehType.twLate - latestFWEnd;
        Duration lateService = 0;
        for (auto client : lateClients)
        {
            ProblemData::Client const &cl = data.location(client);
            lateService += cl.serviceDuration;
        }

        if (lateService > remainingTime)
            continue;

        auto const reloadDepot = vehType.reloadDepots[0];
        for (auto client : lateClients)
        {
            auto *U = &solution_.nodes[client];
            auto const insertIdx = route.size() - 1;
            route.insert(insertIdx, U);
        }
        {
            size_t firstLateIdx = route.size() - 1;
            for (size_t idx = 1; idx < route.size() - 1; ++idx)
            {
                auto *node = route[idx];
                for (auto c : lateClients)
                {
                    if (node->client() == c)
                    {
                        firstLateIdx = idx;
                        goto found;
                    }
                }
            }
        found:
            Route::Node depotNode(reloadDepot);
            route.insert(firstLateIdx, &depotNode);
        }
        route.update();
    }
}

void LocalSearch::improveWithMultiTrip(
    [[maybe_unused]] CostEvaluator const &costEvaluator, bool skipFeasibility)
{
    std::vector<size_t> candidates;
    for (auto client = data.numDepots(); client != data.numLocations();
         ++client)
    {
        auto *U = &solution_.nodes[client];
        if (U->route())
            continue;
        ProblemData::Client const &cd = data.location(client);
        if (cd.prize > 0)
            candidates.push_back(client);
    }

    std::sort(candidates.begin(),
              candidates.end(),
              [&](size_t a, size_t b) -> bool
              {
                  ProblemData::Client const &ca = data.location(a);
                  ProblemData::Client const &cb = data.location(b);
                  return ca.twEarly.get() < cb.twEarly.get();
              });

    for (auto client : candidates)
    {
        auto *U = &solution_.nodes[client];
        if (U->route())
            continue;

        ProblemData::Client const &clientData = data.location(client);

        if (clientData.group)
        {
            auto const &group = data.group(*clientData.group);
            if (group.mutuallyExclusive)
            {
                bool skip = false;
                for (auto member : group.clients())
                {
                    if (member != client && solution_.nodes[member].route())
                    {
                        skip = true;
                        break;
                    }
                }
                if (skip)
                    continue;
            }
        }

        Route *bestRoute = nullptr;
        Cost bestCost = 0;

        for (auto &route : solution_.routes)
        {
            if (route.empty())
                continue;

            auto const &vehType = data.vehicleType(route.vehicleType());

            if (vehType.reloadDepots.empty())
                continue;
            if (route.numTrips() >= route.maxTrips())
                continue;

            if (!skipFeasibility && !route.isFeasible())
                continue;

            bool clientFits = true;
            for (size_t d = 0;
                 d < data.numLoadDimensions() && d < vehType.capacity.size();
                 ++d)
            {
                Load clientDemand = 0;
                if (d < clientData.delivery.size())
                    clientDemand
                        = std::max(clientDemand, clientData.delivery[d]);
                if (d < clientData.pickup.size())
                    clientDemand = std::max(clientDemand, clientData.pickup[d]);

                if (clientDemand > vehType.capacity[d])
                {
                    clientFits = false;
                    break;
                }
            }

            if (!clientFits)
                continue;

            auto const reloadDepot = vehType.reloadDepots[0];
            auto const profile = vehType.profile;
            auto const &distMatrix = data.distanceMatrix(profile);
            auto const &durMatrix = data.durationMatrix(profile);

            auto const dist = distMatrix(reloadDepot, client)
                              + distMatrix(client, reloadDepot);
            auto const dur = durMatrix(reloadDepot, client)
                             + durMatrix(client, reloadDepot)
                             + clientData.serviceDuration;

            auto const shiftDuration = vehType.shiftDuration;
            auto const currentDuration = route.duration();
            if (shiftDuration < std::numeric_limits<Duration>::max())
            {
                Duration reloadTime = 0;
                if (reloadDepot < data.numDepots())
                {
                    ProblemData::Depot const &depot = data.depot(reloadDepot);
                    reloadTime = depot.serviceDuration;
                }

                if (currentDuration + dur + reloadTime > shiftDuration)
                    continue;
            }

            Cost tripCost = -static_cast<Cost>(clientData.prize)
                            + static_cast<Cost>(dist.get());

            if (tripCost < bestCost)
            {
                bestCost = tripCost;
                bestRoute = &route;
            }
        }

        if (bestRoute && bestCost < 0)
        {
            auto const &vehType = data.vehicleType(bestRoute->vehicleType());
            auto const reloadDepot = vehType.reloadDepots[0];
            auto const profile = vehType.profile;
            auto const &durMatrix = data.durationMatrix(profile);

            size_t insertIdx = bestRoute->size() - 1;
            bool foundBoundary = false;

            bool canInsertAtBeginning = false;
            {
                Duration arrive
                    = vehType.twEarly + durMatrix(vehType.startDepot, client);
                arrive = advancePastForbidden(arrive, vehType.forbiddenWindows);
                if (arrive <= clientData.twLate)
                    canInsertAtBeginning = true;
            }

            Duration now = vehType.twEarly;
            for (size_t idx = 0; idx < bestRoute->size(); ++idx)
            {
                auto *node = (*bestRoute)[idx];
                if (idx > 0)
                    now += durMatrix((*bestRoute)[idx - 1]->client(),
                                     node->client());

                now = advancePastForbidden(now, vehType.forbiddenWindows);

                if (node->isReloadDepot() || (node->isDepot() && idx > 0))
                {
                    Duration depart = now;
                    if (node->isReloadDepot())
                    {
                        ProblemData::Depot const &dp
                            = data.location(node->client());
                        depart += dp.serviceDuration;
                        depart = advancePastForbidden(depart,
                                                      vehType.forbiddenWindows);
                    }
                    Duration arrive
                        = depart + durMatrix(node->client(), client);

                    if (arrive <= clientData.twLate)
                    {
                        insertIdx = idx;
                        foundBoundary = true;
                    }
                }

                if (!node->isDepot() && !node->isReloadDepot())
                {
                    ProblemData::Client const &cl
                        = data.location(node->client());
                    auto const wait
                        = cl.twEarly > now ? cl.twEarly - now : Duration(0);
                    now += wait + cl.serviceDuration;
                }
                else if (node->isReloadDepot())
                {
                    ProblemData::Depot const &dp
                        = data.location(node->client());
                    now += dp.serviceDuration;
                    now = advancePastForbidden(now, vehType.forbiddenWindows);
                }
            }

            Route::Node depot = {reloadDepot};
            size_t clientIdx, depotIdx;
            if (!foundBoundary && canInsertAtBeginning)
            {
                bestRoute->insert(1, U);
                bestRoute->insert(2, &depot);
                clientIdx = 1;
                depotIdx = 2;
            }
            else
            {
                bestRoute->insert(insertIdx, U);
                bestRoute->insert(insertIdx, &depot);
                clientIdx = insertIdx + 1;
                depotIdx = insertIdx;
            }
            bestRoute->update();

            if (!bestRoute->isFeasible())
            {
                if (clientIdx > depotIdx)
                {
                    bestRoute->remove(clientIdx);
                    bestRoute->remove(depotIdx);
                }
                else
                {
                    bestRoute->remove(depotIdx);
                    bestRoute->remove(clientIdx);
                }
                bestRoute->update();
                continue;
            }

            searchSpace_.markPromising(U);
        }
    }
}

void LocalSearch::stripForbiddenWindowViolations()
{
    for (auto &route : solution_.routes)
    {
        if (route.empty())
            continue;

        auto const &vehType = data.vehicleType(route.vehicleType());
        if (vehType.forbiddenWindows.empty())
            continue;

        auto const &durations = data.durationMatrix(vehType.profile);
        Duration now = vehType.twEarly;

        std::vector<size_t> toRemove;

        for (size_t idx = 0; idx < route.size(); ++idx)
        {
            auto *node = route[idx];
            if (idx > 0)
                now += durations(route[idx - 1]->client(), node->client());

            now = advancePastForbidden(now, vehType.forbiddenWindows);

            if (node->isDepot() || node->isReloadDepot())
            {
                if (node->isReloadDepot())
                {
                    ProblemData::Depot const &depot
                        = data.location(node->client());
                    now += depot.serviceDuration;
                    now = advancePastForbidden(now, vehType.forbiddenWindows);

                    if (idx + 1 < route.size() && !route[idx + 1]->isDepot()
                        && !route[idx + 1]->isReloadDepot())
                    {
                        auto const travel = durations(node->client(),
                                                      route[idx + 1]->client());
                        auto const arrive = now + travel;
                        ProblemData::Client const &next
                            = data.location(route[idx + 1]->client());
                        auto const svcStart = std::max(arrive, next.twEarly);
                        auto const svcEnd = svcStart + next.serviceDuration;

                        for (auto const &[fStart, fEnd] :
                             vehType.forbiddenWindows)
                        {
                            if (arrive < fEnd && svcEnd > fStart)
                            {
                                if (fEnd > now)
                                    now = fEnd;
                                break;
                            }
                        }
                    }
                }
                continue;
            }

            ProblemData::Client const &cl = data.location(node->client());
            auto const wait = cl.twEarly > now ? cl.twEarly - now : Duration(0);
            now += wait;

            auto const serviceEnd = now + cl.serviceDuration;
            if (serviceEnd > vehType.twLate && !cl.required)
                toRemove.push_back(node->client());

            now = serviceEnd;
        }

        if (toRemove.empty())
            continue;

        for (auto it = toRemove.rbegin(); it != toRemove.rend(); ++it)
        {
            auto *U = &solution_.nodes[*it];
            if (U->route() == &route)
                route.remove(U->idx());
        }

        bool changed = true;
        while (changed)
        {
            changed = false;
            for (size_t idx = 1; idx < route.size() - 1; ++idx)
            {
                if (!route[idx]->isReloadDepot())
                    continue;

                bool orphaned = (idx + 1 >= route.size() - 1)
                                || route[idx + 1]->isDepot()
                                || route[idx + 1]->isReloadDepot();
                if (orphaned)
                {
                    route.remove(idx);
                    changed = true;
                    break;
                }
            }
        }

        route.update();
    }
}

void LocalSearch::stripInfeasibleForbiddenWindowClients()
{
    for (auto &route : solution_.routes)
    {
        if (route.empty() || route.isFeasible())
            continue;

        auto const &vehType = data.vehicleType(route.vehicleType());
        if (vehType.forbiddenWindows.empty())
            continue;

        bool changed = true;
        while (changed && !route.isFeasible())
        {
            changed = false;

            auto const &durations = data.durationMatrix(vehType.profile);
            Duration now = vehType.twEarly;
            size_t worstClient = 0;
            Duration worstOverlap = 0;

            for (size_t idx = 0; idx < route.size(); ++idx)
            {
                auto *node = route[idx];
                if (idx > 0)
                    now += durations(route[idx - 1]->client(), node->client());

                now = advancePastForbidden(now, vehType.forbiddenWindows);

                if (node->isDepot() || node->isReloadDepot())
                {
                    if (node->isReloadDepot())
                    {
                        ProblemData::Depot const &dp
                            = data.location(node->client());
                        now += dp.serviceDuration;
                        now = advancePastForbidden(now,
                                                   vehType.forbiddenWindows);
                    }
                    continue;
                }

                ProblemData::Client const &cl = data.location(node->client());
                if (cl.required)
                {
                    auto const wait
                        = cl.twEarly > now ? cl.twEarly - now : Duration(0);
                    now += wait + cl.serviceDuration;
                    continue;
                }

                auto const wait
                    = cl.twEarly > now ? cl.twEarly - now : Duration(0);
                auto const svcStart = now + wait;
                auto const svcEnd = svcStart + cl.serviceDuration;

                Duration overlap = 0;
                for (auto const &[fStart, fEnd] : vehType.forbiddenWindows)
                {
                    auto const oStart = std::max(svcStart, fStart);
                    auto const oEnd = std::min(svcEnd, fEnd);
                    if (oStart < oEnd)
                        overlap += oEnd - oStart;
                }
                if (svcEnd > vehType.twLate)
                    overlap += svcEnd - vehType.twLate;

                if (overlap > worstOverlap)
                {
                    worstOverlap = overlap;
                    worstClient = node->client();
                }

                now = svcEnd;
            }

            if (worstOverlap > 0)
            {
                auto *U = &solution_.nodes[worstClient];
                if (U->route() == &route)
                {
                    route.remove(U->idx());
                    route.update();
                    changed = true;
                }
            }
        }

        bool cleaned = true;
        while (cleaned)
        {
            cleaned = false;
            for (size_t idx = 1; idx < route.size() - 1; ++idx)
            {
                if (!route[idx]->isReloadDepot())
                    continue;
                bool orphaned = (idx + 1 >= route.size() - 1)
                                || route[idx + 1]->isDepot()
                                || route[idx + 1]->isReloadDepot();
                if (orphaned)
                {
                    route.remove(idx);
                    cleaned = true;
                    break;
                }
            }
        }

        route.update();
    }
}

void LocalSearch::update(Route *U, Route *V)
{
    numUpdates_++;
    searchCompleted_ = false;

    if (U)
    {
        U->update();
        lastUpdated[U->idx()] = numUpdates_;
    }

    if (V && U != V)
    {
        V->update();
        lastUpdated[V->idx()] = numUpdates_;
    }
}

void LocalSearch::loadSolution(pyvrp::Solution const &solution)
{
    std::fill(lastTestedNodes.begin(), lastTestedNodes.end(), -1);
    std::fill(lastTestedRoutes.begin(), lastTestedRoutes.end(), -1);
    std::fill(lastUpdated.begin(), lastUpdated.end(), 0);
    searchSpace_.markAllPromising();
    numUpdates_ = 0;

    solution_.load(solution);

    for (auto *op : unaryOps)
        op->init(solution_);

    for (auto *op : binaryOps)
        op->init(solution_);

    if (swapStar_)
        swapStar_->init();
}

void LocalSearch::addOperator(BinaryOperator &op)
{
    binaryOps.emplace_back(&op);
}

void LocalSearch::addOperator(UnaryOperator &op) { unaryOps.emplace_back(&op); }

void LocalSearch::setSwapStar(SwapStar &op) { swapStar_ = &op; }

std::vector<BinaryOperator *> const &LocalSearch::operators() const
{
    return binaryOps;
}

void LocalSearch::setNeighbours(SearchSpace::Neighbours neighbours)
{
    searchSpace_.setNeighbours(neighbours);
}

SearchSpace::Neighbours const &LocalSearch::neighbours() const
{
    return searchSpace_.neighbours();
}

SearchSpace const &LocalSearch::searchSpace() const { return searchSpace_; }

LocalSearch::Statistics LocalSearch::statistics() const
{
    size_t numMoves = 0;
    size_t numImproving = 0;

    auto const count = [&](auto const *op)
    {
        auto const &stats = op->statistics();
        numMoves += stats.numEvaluations;
        numImproving += stats.numApplications;
    };

    std::for_each(unaryOps.begin(), unaryOps.end(), count);
    std::for_each(binaryOps.begin(), binaryOps.end(), count);

    assert(numImproving <= numUpdates_);
    return {numMoves, numImproving, numUpdates_};
}

LocalSearch::LocalSearch(ProblemData const &data,
                         SearchSpace::Neighbours neighbours,
                         PerturbationManager &perturbationManager)
    : data(data),
      solution_(data),
      searchSpace_(data, neighbours),
      perturbationManager_(perturbationManager),
      lastTestedNodes(data.numLocations()),
      lastTestedRoutes(data.numVehicles()),
      lastUpdated(data.numVehicles()),
      clientToSameVehicleGroups_(data.numLocations())
{
    for (size_t groupIdx = 0; groupIdx != data.numSameVehicleGroups();
         ++groupIdx)
        for (auto const client : data.sameVehicleGroup(groupIdx))
            clientToSameVehicleGroups_[client].push_back(groupIdx);
}

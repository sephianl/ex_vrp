#include "LocalSearch.h"
#include "DynamicBitset.h"
#include "Measure.h"
#include "Trip.h"

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

    ensureStructuralFeasibility(costEvaluator);

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

    search(costEvaluator);

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

    improveWithMultiTrip(costEvaluator);

    return solution_.unload();
}

void LocalSearch::search(CostEvaluator const &costEvaluator)
{
    if (binaryOps.empty() && unaryOps.empty())
        return;

    ensureStructuralFeasibility(costEvaluator);

    searchCompleted_ = false;
    for (int step = 0; !searchCompleted_; ++step)
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

            if (!U->route())
                continue;

            applySameVehicleRepair(U, costEvaluator);

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

            assert(costAfter == costBefore + deltaCost);

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

void LocalSearch::ensureStructuralFeasibility(
    CostEvaluator const &costEvaluator)
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
            auto *U = &solution_.nodes[client];
            solution_.insert(U, searchSpace_, costEvaluator, true);
            if (U->route())
            {
                update(U->route(), U->route());
                searchSpace_.markPromising(U);
            }
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
            if (!group.required)
                continue;

            bool anyInSol = false;
            for (auto const member : group)
            {
                if (solution_.nodes[member].route())
                {
                    anyInSol = true;
                    break;
                }
            }

            if (!anyInSol && group.clients().front() == client)
            {
                auto *U = &solution_.nodes[client];
                solution_.insert(U, searchSpace_, costEvaluator, true);
                if (U->route())
                {
                    update(U->route(), U->route());
                    searchSpace_.markPromising(U);
                }
            }
            continue;
        }
    }

    std::vector<std::pair<Cost, size_t>> costs;
    for (auto const &group : data.groups())
    {
        size_t numInSol = 0;
        for (auto const client : group)
            if (solution_.nodes[client].route())
                numInSol++;

        if (numInSol <= 1)
            continue;

        costs.clear();
        for (auto const client : group)
        {
            if (!solution_.nodes[client].route())
                continue;

            auto *U = &solution_.nodes[client];
            auto *route = U->route();
            Cost deltaCost = 0;
            ProblemData::Client const &cData
                = data.client(client - data.numDepots());
            deltaCost
                = cData.prize
                  - Cost(route->numClients() == 1) * route->fixedVehicleCost();
            costEvaluator.deltaCost<true>(
                deltaCost,
                Route::Proposal(route->before(U->idx() - 1),
                                route->after(U->idx() + 1)));
            costs.emplace_back(deltaCost, client);
        }

        std::sort(costs.begin(),
                  costs.end(),
                  [](auto const &a, auto const &b)
                  { return a.first < b.first; });

        for (size_t i = 0; i + 1 < costs.size(); ++i)
        {
            auto *U = &solution_.nodes[costs[i].second];
            auto *route = U->route();
            searchSpace_.markPromising(U);
            route->remove(U->idx());
            update(route, route);
        }
    }
}

void LocalSearch::improveWithMultiTrip(
    [[maybe_unused]] CostEvaluator const &costEvaluator)
{
    for (auto client = data.numDepots(); client != data.numLocations();
         ++client)
    {
        auto *U = &solution_.nodes[client];
        if (U->route())
            continue;

        ProblemData::Client const &clientData
            = data.client(client - data.numDepots());
        if (clientData.prize <= 0)
            continue;

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

            if (!route.isFeasible())
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

            auto const insertIdx = bestRoute->size() - 1;
            Route::Node depot = {reloadDepot};
            bestRoute->insert(insertIdx, &depot);
            bestRoute->insert(insertIdx + 1, U);
            bestRoute->update();

            searchSpace_.markPromising(U);
        }
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
    std::fill(lastUpdated.begin(), lastUpdated.end(), 0);
    searchSpace_.markAllPromising();
    numUpdates_ = 0;

    solution_.load(solution);

    for (auto *op : unaryOps)
        op->init(solution_);

    for (auto *op : binaryOps)
        op->init(solution_);
}

void LocalSearch::addOperator(BinaryOperator &op)
{
    binaryOps.emplace_back(&op);
}

void LocalSearch::addOperator(UnaryOperator &op) { unaryOps.emplace_back(&op); }

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
      lastUpdated(data.numVehicles()),
      clientToSameVehicleGroups_(data.numLocations())
{
    for (size_t groupIdx = 0; groupIdx != data.numSameVehicleGroups();
         ++groupIdx)
        for (auto const client : data.sameVehicleGroup(groupIdx))
            clientToSameVehicleGroups_[client].push_back(groupIdx);
}

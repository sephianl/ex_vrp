#include "LocalSearch.h"
#include "DynamicBitset.h"
#include "Measure.h"
#include "Trip.h"
#include "primitives.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstring>
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

    markRequiredMissingAsPromising();

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

    while (true)
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

    search(costEvaluator);

    improveWithMultiTrip(costEvaluator);

    return solution_.unload();
}

pyvrp::Solution LocalSearch::intensify(pyvrp::Solution const &solution,
                                       CostEvaluator const &costEvaluator)
{
    loadSolution(solution);
    intensify(costEvaluator);
    return solution_.unload();
}

void LocalSearch::search(CostEvaluator const &costEvaluator)
{
    if (binaryOps.empty())
        return;

    markRequiredMissingAsPromising();

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

            bool shouldTest = (lastTested == -1);
            if (!shouldTest && U->route())
            {
                shouldTest = (lastUpdated[U->route()->idx()] > lastTested);
            }

            if (shouldTest)
                applyOptionalClientMoves(U, costEvaluator);

            applyGroupMoves(U, costEvaluator);

            if (!U->route())
                continue;

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
    if (routeOps.empty())
        return;

    searchCompleted_ = false;
    while (!searchCompleted_)
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
                    applyRouteOps(U, V, costEvaluator);
            }
        }
    }
}

void LocalSearch::shuffle(RandomNumberGenerator &rng)
{
    perturbationManager_.shuffle(rng);
    searchSpace_.shuffle(rng);

    rng.shuffle(binaryOps.begin(), binaryOps.end());
    rng.shuffle(routeOps.begin(), routeOps.end());
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
            if (otherNode->route() == currentRoute)
                return true;
        }
    }

    return false;
}

bool LocalSearch::applyBinaryOps(Route::Node *U,
                                 Route::Node *V,
                                 CostEvaluator const &costEvaluator)
{
    auto *rU = U->route();
    auto *rV = V->route();

    if (rU != rV)
    {
        if (wouldViolateSameVehicle(U, rV) || wouldViolateSameVehicle(V, rU))
            return false;
    }

    for (auto *op : binaryOps)
    {
        auto [deltaCost, applied] = op->evaluate(U, V, costEvaluator);
        if (deltaCost < 0)
        {
            [[maybe_unused]] auto const costBefore
                = costEvaluator.penalisedCost(*rU)
                  + Cost(rU != rV) * costEvaluator.penalisedCost(*rV);

            searchSpace_.markPromising(U);
            searchSpace_.markPromising(V);

            if (!applied)
                op->apply(U, V);
            update(rU, rV);

            [[maybe_unused]] auto const costAfter
                = costEvaluator.penalisedCost(*rU)
                  + Cost(rU != rV) * costEvaluator.penalisedCost(*rV);

            assert(costAfter == costBefore + deltaCost);

            return true;
        }
    }

    return false;
}

bool LocalSearch::applyRouteOps(Route *U,
                                Route *V,
                                CostEvaluator const &costEvaluator)
{
    for (auto *routeOp : routeOps)
    {
        auto [deltaCost, applied]
            = routeOp->evaluate((*U)[0], (*V)[0], costEvaluator);
        if (deltaCost < 0)
        {
            [[maybe_unused]] auto const costBefore
                = costEvaluator.penalisedCost(*U)
                  + Cost(U != V) * costEvaluator.penalisedCost(*V);

            if (!applied)
                routeOp->apply((*U)[0], (*V)[0]);
            update(U, V);

            [[maybe_unused]] auto const costAfter
                = costEvaluator.penalisedCost(*U)
                  + Cost(U != V) * costEvaluator.penalisedCost(*V);

            assert(costAfter == costBefore + deltaCost);

            return true;
        }
    }

    return false;
}

void LocalSearch::applyDepotRemovalMove(Route::Node *U,
                                        CostEvaluator const &costEvaluator)
{
    if (!U->isReloadDepot())
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

void LocalSearch::applyOptionalClientMoves(Route::Node *U,
                                           CostEvaluator const &costEvaluator)
{
    ProblemData::Client const &uData = data.location(U->client());

    if (uData.required && !U->route())
    {
        solution_.insert(U, searchSpace_, costEvaluator, true);
        update(U->route(), U->route());
        searchSpace_.markPromising(U);
    }

    if (uData.required || uData.group)
        return;

    if (!wouldViolateSameVehicle(U, nullptr)
        && removeCost(U, data, costEvaluator) < 0)
    {
        searchSpace_.markPromising(U);
        auto *route = U->route();
        route->remove(U->idx());
        update(route, route);
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

        ProblemData::Client const &vData = data.location(V->client());

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
    ProblemData::Client const &uData = data.location(U->client());

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

void LocalSearch::markRequiredMissingAsPromising()
{
    for (auto client = data.numDepots(); client != data.numLocations();
         ++client)
    {
        if (solution_.nodes[client].route())
            continue;

        ProblemData::Client const &clientData = data.location(client);
        if (clientData.required)
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
                continue;
            }
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

        ProblemData::Client const &clientData = data.location(client);
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
                    ProblemData::Depot const &depot
                        = data.location(reloadDepot);
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

    U->update();
    lastUpdated[U->idx()] = numUpdates_;

    for (auto *op : binaryOps)
        op->update(U);

    for (auto *op : routeOps)
        op->update(U);

    if (U != V)
    {
        V->update();
        lastUpdated[V->idx()] = numUpdates_;

        for (auto *op : binaryOps)
            op->update(V);

        for (auto *op : routeOps)
            op->update(V);
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

    for (auto *op : routeOps)
        op->init(solution_);
}

void LocalSearch::addOperator(BinaryOperator &op)
{
    binaryOps.emplace_back(&op);
}

void LocalSearch::addRouteOperator(BinaryOperator &op)
{
    routeOps.emplace_back(&op);
}

void LocalSearch::addOperator(UnaryOperator &op) { unaryOps.emplace_back(&op); }

std::vector<BinaryOperator *> const &LocalSearch::operators() const
{
    return binaryOps;
}

std::vector<BinaryOperator *> const &LocalSearch::routeOperators() const
{
    return routeOps;
}

void LocalSearch::setNeighbours(SearchSpace::Neighbours neighbours)
{
    searchSpace_.setNeighbours(neighbours);
}

SearchSpace::Neighbours const &LocalSearch::neighbours() const
{
    return searchSpace_.neighbours();
}

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

    std::for_each(binaryOps.begin(), binaryOps.end(), count);
    std::for_each(routeOps.begin(), routeOps.end(), count);

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

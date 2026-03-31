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
using pyvrp::search::LocalSearch;
using pyvrp::search::NodeOperator;
using pyvrp::search::RouteOperator;
using pyvrp::search::SearchSpace;

pyvrp::Solution LocalSearch::operator()(pyvrp::Solution const &solution,
                                        CostEvaluator const &costEvaluator,
                                        bool exhaustive,
                                        int64_t timeout_ms)
{
    loadSolution(solution);

    if (!exhaustive)
        perturbationManager_.perturb(solution_, searchSpace_, costEvaluator);

    markMissingAsPromising();

    // Set up timeout tracking
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

        // Check timeout after search
        if (has_timeout_
            && std::chrono::steady_clock::now() >= timeout_deadline_)
            break;

        auto const numUpdates = numUpdates_;

        intensify(costEvaluator);

        // Check timeout after intensify
        if (has_timeout_
            && std::chrono::steady_clock::now() >= timeout_deadline_)
            break;

        if (numUpdates_ == numUpdates)
            // Then intensify (route search) did not do any additional
            // updates, so the solution is locally optimal.
            break;
    }

    return solution_.unload();
}

pyvrp::Solution LocalSearch::search(pyvrp::Solution const &solution,
                                    CostEvaluator const &costEvaluator,
                                    int64_t timeout_ms)
{
    loadSolution(solution);

    // Set up timeout tracking (same as operator())
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

    // TODO: insertConstrainedFirst disabled while debugging crash
    // insertConstrainedFirst(costEvaluator);

    search(costEvaluator);

    // After the main search, try to insert unassigned clients via multi-trip.
    // This is a one-time pass (not iterative) so it won't cause loops.
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
    if (nodeOps.empty())
        return;

    markMissingAsPromising();

    searchCompleted_ = false;
    for (int step = 0; !searchCompleted_; ++step)
    {
        // Check timeout
        if (has_timeout_
            && std::chrono::steady_clock::now() >= timeout_deadline_)
            return;

        searchCompleted_ = true;

        // Node operators are evaluated for neighbouring (U, V) pairs.
        for (auto const uClient : searchSpace_.clientOrder())
        {
            if (!searchSpace_.isPromising(uClient))
                continue;

            auto *U = &solution_.nodes[uClient];

            auto const lastTested = lastTestedNodes[U->client()];
            lastTestedNodes[U->client()] = numUpdates_;

            // First test removing or inserting U. Particularly relevant if not
            // all clients are required (e.g., when prize collecting).
            // Only test if solution changed since last test (prevents
            // oscillation)
            bool shouldTest = (lastTested == -1);  // First time
            if (!shouldTest && U->route())
            {
                // For routed clients, check if route was updated
                shouldTest = (lastUpdated[U->route()->idx()] > lastTested);
            }

            if (shouldTest)
                applyOptionalClientMoves(U, costEvaluator);

            // Evaluate moves involving the client's group, if it is in any.
            applyGroupMoves(U, costEvaluator);

            if (!U->route())  // we already evaluated inserting U, so there is
                continue;     // nothing left to be done for this client.

            // TODO: applySameVehicleRepair has an OOB bug in insertCost
            // evaluation that causes segfaults. Disabled until fixed.
            // applySameVehicleRepair(U, costEvaluator);

            // If U borders a reload depot, try removing it.
            applyDepotRemovalMove(p(U), costEvaluator);
            applyDepotRemovalMove(n(U), costEvaluator);

            // We next apply the regular operators that work on pairs of nodes
            // (U, V), where both U and V are in the solution.
            for (auto const vClient : searchSpace_.neighboursOf(U->client()))
            {
                auto *V = &solution_.nodes[vClient];

                if (!V->route())
                    continue;

                if (lastUpdated[U->route()->idx()] > lastTested
                    || lastUpdated[V->route()->idx()] > lastTested)
                {
                    if (applyNodeOps(U, V, costEvaluator))
                        continue;

                    if (p(V)->isStartDepot()
                        && applyNodeOps(U, p(V), costEvaluator))
                        continue;
                }
            }

            // Moves involving empty routes are not tested in the first
            // iteration to avoid using too many routes.
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
        // Check timeout
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

    rng.shuffle(nodeOps.begin(), nodeOps.end());
    rng.shuffle(routeOps.begin(), routeOps.end());
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
    // If U is not in any same-vehicle group, moving it is always allowed.
    auto const &groups = clientToSameVehicleGroups_[U->client()];
    if (groups.empty())
        return false;

    auto const *currentRoute = U->route();

    // If U is not currently in a route, or moving to the same route, no
    // violation is possible.
    if (!currentRoute || currentRoute == targetRoute)
        return false;

    // If the target route exists and has the same vehicle name as the current
    // route, moving is allowed (same vehicle with different shifts).
    if (targetRoute)
    {
        auto const *currentName
            = data.vehicleType(currentRoute->vehicleType()).name;
        auto const *targetName
            = data.vehicleType(targetRoute->vehicleType()).name;

        // If both have the same non-empty name, they represent the same
        // vehicle (possibly with different shifts), so moving is allowed.
        if (currentName && targetName && currentName[0] != '\0'
            && std::strcmp(currentName, targetName) == 0)
            return false;
    }

    // Check each same-vehicle group U belongs to.
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

bool LocalSearch::applyNodeOps(Route::Node *U,
                               Route::Node *V,
                               CostEvaluator const &costEvaluator)
{
    auto *rU = U->route();
    auto *rV = V->route();

    // Skip if moving U to V's route (or vice versa) would violate same-vehicle
    // constraints or place a client on a zone-forbidden route.
    if (rU != rV)
    {
        if (wouldViolateSameVehicle(U, rV) || wouldViolateSameVehicle(V, rU))
            return false;
        if (wouldViolateForbidden(U, rV) || wouldViolateForbidden(V, rU))
            return false;
    }

    for (auto *nodeOp : nodeOps)
    {
        auto const deltaCost = nodeOp->evaluate(U, V, costEvaluator);
        if (deltaCost < 0)
        {
            [[maybe_unused]] auto const costBefore
                = costEvaluator.penalisedCost(*rU)
                  + Cost(rU != rV) * costEvaluator.penalisedCost(*rV);

            searchSpace_.markPromising(U);
            searchSpace_.markPromising(V);

            nodeOp->apply(U, V);
            update(rU, rV);

            [[maybe_unused]] auto const costAfter
                = costEvaluator.penalisedCost(*rU)
                  + Cost(rU != rV) * costEvaluator.penalisedCost(*rV);

            // When there is an improving move, the delta cost evaluation must
            // be exact. The resulting cost is then the sum of the cost before
            // the move, plus the delta cost.
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
        auto const deltaCost = routeOp->evaluate(U, V, costEvaluator);
        if (deltaCost < 0)
        {
            [[maybe_unused]] auto const costBefore
                = costEvaluator.penalisedCost(*U)
                  + Cost(U != V) * costEvaluator.penalisedCost(*V);

            routeOp->apply(U, V);
            update(U, V);

            [[maybe_unused]] auto const costAfter
                = costEvaluator.penalisedCost(*U)
                  + Cost(U != V) * costEvaluator.penalisedCost(*V);

            // When there is an improving move, the delta cost evaluation must
            // be exact. The resulting cost is then the sum of the cost before
            // the move, plus the delta cost.
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

    // We remove the depot when that's either better, or neutral. It can be
    // neutral if for example it's the same depot visited consecutively, but
    // that's then unnecessary.
    if (removeCost(U, data, costEvaluator) <= 0)
    {
        searchSpace_.markPromising(U);  // U's neighbours might not be depots
        auto *route = U->route();
        route->remove(U->idx());
        update(route, route);
    }
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

            // Partner V is on a different route. Try inserting U on V's
            // route at the best position. Accept if the total cost
            // (including SVG penalty savings) is improving.
            auto *rU = U->route();
            auto *rV = V->route();

            if (wouldViolateForbidden(U, rV))
                continue;

            // Cost of removing U from its current route
            Cost remCost = removeCost(U, data, costEvaluator);

            // Find best insertion position on V's route (exclude end depot)
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

            // Accept if removal + insertion + SVG penalty bonus < 0.
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

void LocalSearch::applyEmptyRouteMoves(Route::Node *U,
                                       CostEvaluator const &costEvaluator)
{
    assert(U->route());

    // We apply moves involving empty routes in the (randomised) order of
    // orderVehTypes. This helps because empty vehicle moves incur fixed cost,
    // and a purely greedy approach over-prioritises vehicles with low fixed
    // costs but possibly high variable costs.
    for (auto const &[vehType, offset] : searchSpace_.vehTypeOrder())
    {
        auto const begin = solution_.routes.begin() + offset;
        auto const end = begin + data.vehicleType(vehType).numAvailable;
        auto const pred = [](auto const &route) { return route.empty(); };
        auto empty = std::find_if(begin, end, pred);

        if (empty != end && applyNodeOps(U, (*empty)[0], costEvaluator))
            break;
    }
}

void LocalSearch::applyOptionalClientMoves(Route::Node *U,
                                           CostEvaluator const &costEvaluator)
{
    ProblemData::Client const &uData = data.location(U->client());

    if (uData.required && !U->route())  // then we must insert U
    {
        if (solution_.insert(U, searchSpace_, costEvaluator, true))
        {
            update(U->route(), U->route());
            searchSpace_.markPromising(U);
        }
    }

    // Required clients are not optional, and have just been inserted above
    // if not already in the solution. Groups have their own operator and are
    // not processed here.
    if (uData.required || uData.group)
        return;

    // Don't remove U if it would violate same-vehicle constraints, or if
    // U is zone-restricted to very few vehicles (removing would likely leave
    // it unassigned since reinsertion options are severely limited).
    if (!wouldViolateSameVehicle(U, nullptr) && !isHardToPlace(U)
        && removeCost(U, data, costEvaluator) < 0)  // remove if improving
    {
        searchSpace_.markPromising(U);
        auto *route = U->route();
        route->remove(U->idx());
        update(route, route);
    }

    if (U->route())
        return;

    // Attempt to insert U into the solution. This considers both existing
    // routes (via neighbourhood search) and empty routes, inserting U if doing
    // so improves the objective.
    if (solution_.insert(U, searchSpace_, costEvaluator, false))
    {
        update(U->route(), U->route());
        searchSpace_.markPromising(U);
        return;
    }

    // If neighbourhood-based insertion failed, try replacing another optional
    // client with U if that would be improving.
    for (auto const vClient : searchSpace_.neighboursOf(U->client()))
    {
        auto *V = &solution_.nodes[vClient];
        auto *route = V->route();

        if (!route)
            continue;

        ProblemData::Client const &vData = data.location(V->client());

        // Check same-vehicle constraint for V before removing it.
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

    // We remove clients in order of increasing cost delta (biggest improvement
    // first), and evaluate swapping the last client with U.
    std::vector<Cost> costs;
    for (auto const client : inSol)
    {
        auto cost = removeCost(&solution_.nodes[client], data, costEvaluator);
        costs.push_back(cost);
    }

    // Sort clients in order of increasing removal costs.
    std::vector<size_t> range(inSol.size());
    std::iota(range.begin(), range.end(), 0);
    std::sort(range.begin(),
              range.end(),
              [&costs](auto idx1, auto idx2)
              { return costs[idx1] < costs[idx2]; });

    // Remove all but the last client, whose removal is the least valuable.
    for (auto idx = range.begin(); idx != range.end() - 1; ++idx)
    {
        auto const client = inSol[*idx];
        auto const &node = solution_.nodes[client];
        auto *route = node.route();

        searchSpace_.markPromising(&node);
        route->remove(node.idx());
        update(route, route);
    }

    // Test swapping U and V, and do so if U is better to have than V.
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

void LocalSearch::insertConstrainedFirst(CostEvaluator const &costEvaluator)
{
    // Phase 1: Insert same-vehicle group members together on a jointly
    // reachable route. This ensures SVG feasibility from the start —
    // the search's wouldViolateSameVehicle check will then maintain it.
    for (size_t groupIdx = 0; groupIdx < data.numSameVehicleGroups();
         ++groupIdx)
    {
        auto const &group = data.sameVehicleGroup(groupIdx);

        // Skip if any member is already placed
        bool anyPlaced = false;
        for (auto const client : group)
            if (solution_.nodes[client].route())
                anyPlaced = true;
        if (anyPlaced)
            continue;

        // Find a route reachable by ALL group members
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

            // Insert all group members on this route (before end depot)
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

    // Phase 2: Insert zone-restricted clients (few reachable routes).
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

void LocalSearch::markMissingAsPromising()
{
    for (auto client = data.numDepots(); client != data.numLocations();
         ++client)
    {
        if (solution_.nodes[client].route())  // then it's not missing, so
            continue;                         // nothing to do

        ProblemData::Client const &clientData = data.location(client);
        if (clientData.required)
        {
            searchSpace_.markPromising(client);
            continue;
        }

        // Mark unassigned prize clients as promising so the search considers
        // inserting them even when perturbation didn't reach them.
        if (clientData.prize > 0)
        {
            searchSpace_.markPromising(client);
            continue;
        }

        if (clientData.group)  // mark the group's first client as promising so
        {                      // the group at least gets inserted if needed
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
    // This function tries to insert unassigned clients with prizes by creating
    // new trips. Unlike the main local search insert logic, this is a one-time
    // pass that won't cause infinite loops.
    //
    // For each unassigned client with a prize:
    // 1. Check if the client fits alone in a trip (capacity check)
    // 2. Find a route with multi-trip capability
    // 3. Estimate if adding a new trip is beneficial (prize vs travel cost)
    // 4. If yes, insert the client as a new trip

    for (auto client = data.numDepots(); client != data.numLocations();
         ++client)
    {
        auto *U = &solution_.nodes[client];
        if (U->route())  // already assigned
            continue;

        ProblemData::Client const &clientData = data.location(client);
        if (clientData.prize <= 0)  // no prize, skip
            continue;

        // Find the best route to add a new trip
        Route *bestRoute = nullptr;
        Cost bestCost = 0;  // Must be negative to be worth inserting

        for (auto &route : solution_.routes)
        {
            if (route.empty())
                continue;

            auto const &vehType = data.vehicleType(route.vehicleType());

            // Check if multi-trip is available
            if (vehType.reloadDepots.empty())
                continue;
            if (route.numTrips() >= route.maxTrips())
                continue;

            // Check if route is currently feasible (avoid making bad routes
            // worse)
            if (!route.isFeasible())
                continue;

            // Check if client fits alone in a trip
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

            // Estimate the cost of adding a new trip
            auto const reloadDepot = vehType.reloadDepots[0];
            auto const profile = vehType.profile;
            auto const &distMatrix = data.distanceMatrix(profile);
            auto const &durMatrix = data.durationMatrix(profile);

            auto const dist = distMatrix(reloadDepot, client)
                              + distMatrix(client, reloadDepot);
            auto const dur = durMatrix(reloadDepot, client)
                             + durMatrix(client, reloadDepot)
                             + clientData.serviceDuration;

            // Check if adding this trip would exceed shift duration
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
                    continue;  // Would exceed shift duration
            }

            // Calculate cost: prize gained minus travel cost
            Cost tripCost = -static_cast<Cost>(clientData.prize)
                            + static_cast<Cost>(dist.get());

            if (tripCost < bestCost)
            {
                bestCost = tripCost;
                bestRoute = &route;
            }
        }

        // If we found a beneficial route, insert the client
        if (bestRoute && bestCost < 0)
        {
            auto const &vehType = data.vehicleType(bestRoute->vehicleType());
            auto const reloadDepot = vehType.reloadDepots[0];

            // Insert at the end of the route as a new trip
            auto const insertIdx = bestRoute->size() - 1;  // Before end depot
            Route::Node depot = {reloadDepot};
            bestRoute->insert(insertIdx, &depot);
            bestRoute->insert(insertIdx + 1, U);
            bestRoute->update();

            // Mark as promising for future iterations
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

    for (auto *op : routeOps)  // this is used by some route operators
        op->update(U);         // to keep caches in sync.

    if (U != V)
    {
        V->update();
        lastUpdated[V->idx()] = numUpdates_;

        for (auto *op : routeOps)  // this is used by some route operators
            op->update(V);         // to keep caches in sync.
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

    for (auto *nodeOp : nodeOps)
        nodeOp->init(solution);

    for (auto *routeOp : routeOps)
        routeOp->init(solution);
}

void LocalSearch::addNodeOperator(NodeOperator &op)
{
    nodeOps.emplace_back(&op);
}

void LocalSearch::addRouteOperator(RouteOperator &op)
{
    routeOps.emplace_back(&op);
}

std::vector<NodeOperator *> const &LocalSearch::nodeOperators() const
{
    return nodeOps;
}

std::vector<RouteOperator *> const &LocalSearch::routeOperators() const
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

    std::for_each(nodeOps.begin(), nodeOps.end(), count);
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
    // Build client-to-same-vehicle-groups lookup for efficient constraint
    // checking during local search.
    for (size_t groupIdx = 0; groupIdx != data.numSameVehicleGroups();
         ++groupIdx)
        for (auto const client : data.sameVehicleGroup(groupIdx))
            clientToSameVehicleGroups_[client].push_back(groupIdx);
}

#include "Solution.h"

#include "primitives.h"

#include <algorithm>
#include <cassert>
#include <cstring>
#include <iterator>
#include <limits>

using pyvrp::search::Solution;

Solution::Solution(ProblemData const &data) : data_(data)
{
    nodes.reserve(data.numLocations());
    for (size_t loc = 0; loc != data.numLocations(); ++loc)
        nodes.emplace_back(loc);

    routes.reserve(data.numVehicles());
    size_t rIdx = 0;
    for (size_t vehType = 0; vehType != data.numVehicleTypes(); ++vehType)
    {
        auto const numAvailable = data.vehicleType(vehType).numAvailable;
        for (size_t vehicle = 0; vehicle != numAvailable; ++vehicle)
            routes.emplace_back(data, rIdx++, vehType);
    }
}

void Solution::load(pyvrp::Solution const &solution)
{
    // Determine offsets for vehicle types.
    std::vector<size_t> vehicleOffset(data_.numVehicleTypes(), 0);
    for (size_t vehType = 1; vehType < data_.numVehicleTypes(); vehType++)
    {
        auto const prevAvail = data_.vehicleType(vehType - 1).numAvailable;
        vehicleOffset[vehType] = vehicleOffset[vehType - 1] + prevAvail;
    }

    for (auto const &solRoute : solution.routes())
    {
        // Determine index of next route of this type to load, where we rely
        // on solution to be valid to not exceed the number of vehicles per
        // vehicle type.
        auto const idx = vehicleOffset[solRoute.vehicleType()]++;
        auto &route = routes[idx];

        if (route == solRoute)  // then the current route is still OK and we
            continue;           // can skip inserting and updating

        // Else we need to clear the route and insert the updated route from
        // the solution.
        route.clear();

        // Routes use a representation with nodes for each client, reload depot
        // (one per trip), and start/end depots. The start depot doubles as the
        // reload depot for the first trip.
        route.reserve(solRoute.size() + solRoute.numTrips() + 1);

        for (size_t tripIdx = 0; tripIdx != solRoute.numTrips(); ++tripIdx)
        {
            auto const &trip = solRoute.trip(tripIdx);

            if (tripIdx != 0)  // then we first insert a trip delimiter.
            {
                Route::Node depot = {trip.startDepot()};
                route.push_back(&depot);
            }

            for (auto const client : trip)
                route.push_back(&nodes[client]);
        }

        route.update();
    }

    // Finally, we clear any routes that we have not re-used or inserted from
    // the solution.
    size_t firstOfType = 0;
    for (size_t vehType = 0; vehType != data_.numVehicleTypes(); ++vehType)
    {
        auto const numAvailable = data_.vehicleType(vehType).numAvailable;
        auto const firstOfNextType = firstOfType + numAvailable;
        for (size_t idx = vehicleOffset[vehType]; idx != firstOfNextType; ++idx)
            routes[idx].clear();

        firstOfType = firstOfNextType;
    }
}

pyvrp::Solution Solution::unload() const
{
    std::vector<pyvrp::Route> solRoutes;
    solRoutes.reserve(data_.numVehicles());

    std::vector<size_t> visits;

    for (auto const &route : routes)
    {
        if (route.empty())
            continue;

        std::vector<Trip> trips;
        trips.reserve(route.numTrips());

        visits.clear();
        visits.reserve(route.numClients());

        auto const *prevDepot = route[0];
        for (size_t idx = 1; idx != route.size(); ++idx)
        {
            auto const *node = route[idx];

            if (!node->isDepot())
            {
                visits.push_back(node->client());
                continue;
            }

            trips.emplace_back(data_,
                               visits,
                               route.vehicleType(),
                               prevDepot->client(),
                               node->client());

            visits.clear();
            prevDepot = node;
        }

        assert(trips.size() == route.numTrips());
        solRoutes.emplace_back(data_, std::move(trips), route.vehicleType());
    }

    return {data_, std::move(solRoutes)};
}

bool Solution::insert(Route::Node *U,
                      SearchSpace const &searchSpace,
                      CostEvaluator const &costEvaluator,
                      bool required)
{
    assert(size_t(std::distance(nodes.data(), U)) < nodes.size());

    // Check if U is in any same-vehicle group and find the required route.
    // If any group member is already in a route, U must go into that same route
    // (or a route with the same vehicle name for multi-shift scenarios).
    Route *requiredRoute = nullptr;
    char const *requiredVehicleName = nullptr;

    for (size_t groupIdx = 0; groupIdx != data_.numSameVehicleGroups();
         ++groupIdx)
    {
        auto const &group = data_.sameVehicleGroup(groupIdx);

        // Check if U is in this group
        bool uInGroup = false;
        for (auto const client : group)
        {
            if (client == U->client())
            {
                uInGroup = true;
                break;
            }
        }

        if (!uInGroup)
            continue;

        // U is in this group - check if any other member is in a route
        for (auto const otherClient : group)
        {
            if (otherClient == U->client())
                continue;

            auto *otherNode = &nodes[otherClient];
            if (otherNode->route())
            {
                requiredRoute = otherNode->route();
                requiredVehicleName
                    = data_.vehicleType(requiredRoute->vehicleType()).name;
                break;
            }
        }

        if (requiredRoute)
            break;
    }

    // Helper to check if a route is compatible with the required route
    auto isCompatibleRoute = [&](Route const *route) -> bool
    {
        if (!requiredRoute)
            return true;  // No constraint

        if (route == requiredRoute)
            return true;  // Same route

        // Check if vehicles have the same name (multi-shift scenario)
        if (requiredVehicleName && requiredVehicleName[0] != '\0')
        {
            auto const *routeName
                = data_.vehicleType(route->vehicleType()).name;
            if (routeName && routeName[0] != '\0'
                && std::strcmp(requiredVehicleName, routeName) == 0)
                return true;
        }

        return false;
    };

    Route::Node *UAfter = nullptr;
    auto bestCost = std::numeric_limits<Cost>::max();

    // Initialize fallback to the first compatible route
    for (auto &route : routes)
    {
        if (isCompatibleRoute(&route))
        {
            UAfter = route[0];
            bestCost = insertCost(U, UAfter, data_, costEvaluator);
            break;
        }
    }

    // If no compatible route found, we cannot insert
    if (!UAfter)
        return false;

    // First attempt a neighbourhood search to place U into routes that are
    // already in use.
    for (auto const vClient : searchSpace.neighboursOf(U->client()))
    {
        auto *V = &nodes[vClient];

        if (!V->route() || !isCompatibleRoute(V->route()))
            continue;

        auto const cost = insertCost(U, V, data_, costEvaluator);
        if (cost < bestCost)
        {
            bestCost = cost;
            UAfter = V;
        }
    }

    // Next consider all routes (empty and non-empty). For non-empty routes,
    // try inserting at the start (after depot). This handles the case where
    // U is not in the neighbourhood of any client in the route.
    for (auto const &[vehType, offset] : searchSpace.vehTypeOrder())
    {
        auto const begin = routes.begin() + offset;
        auto const end = begin + data_.vehicleType(vehType).numAvailable;

        for (auto it = begin; it != end; ++it)
        {
            if (!isCompatibleRoute(&*it))
                continue;

            // For non-empty routes, only try if we haven't found something via
            // neighbourhood (the neighbourhood search is more thorough for
            // non-empty routes since it evaluates multiple positions).
            if (!it->empty() && UAfter->route() == &*it)
                continue;

            auto const cost = insertCost(U, (*it)[0], data_, costEvaluator);
            if (cost < bestCost)
            {
                bestCost = cost;
                UAfter = (*it)[0];

                // For empty routes, stop at the first improving one.
                if (it->empty())
                    break;
            }
        }
    }

    if (required || bestCost < 0)
    {
        auto *route = UAfter->route();

        // Check if insertion would exceed capacity
        auto const &vehType = data_.vehicleType(route->vehicleType());
        bool wouldExceedCapacity = false;

        // Only check capacity if we have load dimensions, capacity defined,
        // reload depots available for multi-trip, and we can still add trips
        if (data_.numLoadDimensions() > 0 && !vehType.capacity.empty()
            && !vehType.reloadDepots.empty()
            && route->numTrips() < route->maxTrips())
        {
            // U->client() returns location index (which includes depots)
            // For clients, location index = client index (0-based among
            // clients) So we need to check if it's actually a client
            auto const clientLoc = U->client();
            if (clientLoc >= data_.numDepots())  // It's a client, not a depot
            {
                ProblemData::Client const &clientData
                    = data_.location(clientLoc);
                for (size_t d = 0; d < data_.numLoadDimensions()
                                   && d < vehType.capacity.size();
                     ++d)
                {
                    Load currentLoad = 0;
                    // Sum load from start of current trip up to insertion point
                    // Skip depots (start depot is at idx 0, reload depots are
                    // isReloadDepot()) Don't iterate beyond the last client
                    // (end depot is at size()-1)
                    auto const lastClientIdx
                        = route->size() > 2 ? route->size() - 2 : 0;
                    auto const maxIdx = std::min(UAfter->idx(), lastClientIdx);
                    for (size_t i = 1; i <= maxIdx; ++i)
                    {
                        auto *node = route->operator[](i);
                        if (node->isReloadDepot())
                        {
                            // Trip boundary - reset load
                            currentLoad = 0;
                        }
                        else if (node->client() >= data_.numDepots())
                        {
                            // It's a client
                            ProblemData::Client const &loc
                                = data_.location(node->client());
                            if (d < loc.delivery.size())
                                currentLoad = currentLoad + loc.delivery[d];
                            if (d < loc.pickup.size())
                                currentLoad = currentLoad + loc.pickup[d];
                        }
                    }

                    // Add the new client's load
                    Load clientLoad = 0;
                    if (d < clientData.delivery.size())
                        clientLoad = clientLoad + clientData.delivery[d];
                    if (d < clientData.pickup.size())
                        clientLoad = clientLoad + clientData.pickup[d];

                    if (currentLoad + clientLoad > vehType.capacity[d])
                    {
                        wouldExceedCapacity = true;
                        break;
                    }
                }
            }
        }

        // If would exceed capacity and multi-trip is available, insert depot
        // first
        if (wouldExceedCapacity && !vehType.reloadDepots.empty()
            && route->numTrips() < route->maxTrips())
        {
            // Capture index before insert, as insert may reallocate and
            // invalidate UAfter pointer
            auto const insertIdx = UAfter->idx() + 1;
            Route::Node depot = {vehType.reloadDepots[0]};
            route->insert(insertIdx, &depot);
            route->insert(insertIdx + 1, U);
        }
        else
        {
            route->insert(UAfter->idx() + 1, U);
        }
        return true;
    }

    return false;
}

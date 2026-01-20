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

    Route *requiredRoute = nullptr;
    char const *requiredVehicleName = nullptr;

    for (size_t groupIdx = 0; groupIdx != data_.numSameVehicleGroups();
         ++groupIdx)
    {
        auto const &group = data_.sameVehicleGroup(groupIdx);

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

    auto isCompatibleRoute = [&](Route const *route) -> bool
    {
        if (!requiredRoute)
            return true;

        if (route == requiredRoute)
            return true;

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

    for (auto &route : routes)
    {
        if (isCompatibleRoute(&route))
        {
            UAfter = route[0];
            bestCost = insertCost(U, UAfter, data_, costEvaluator);
            break;
        }
    }

    if (!UAfter)
        return false;

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

    for (auto const &[vehType, offset] : searchSpace.vehTypeOrder())
    {
        auto const begin = routes.begin() + offset;
        auto const end = begin + data_.vehicleType(vehType).numAvailable;

        for (auto it = begin; it != end; ++it)
        {
            if (!isCompatibleRoute(&*it))
                continue;

            if (!it->empty() && UAfter->route() == &*it)
                continue;

            auto const cost = insertCost(U, (*it)[0], data_, costEvaluator);
            if (cost < bestCost)
            {
                bestCost = cost;
                UAfter = (*it)[0];

                if (it->empty())
                    break;
            }
        }
    }

    // Compute wouldExceedCapacity BEFORE the insertion decision.
    // This determines if multi-trip could help resolve the capacity issue.
    bool wouldExceedCapacity = false;
    bool canUseMultiTrip = false;
    bool hasPrize = false;
    bool clientFitsAlone = true;  // Does client fit in a single trip by itself?

    if (UAfter && UAfter->route())
    {
        auto *route = UAfter->route();
        auto const &vehType = data_.vehicleType(route->vehicleType());
        canUseMultiTrip = !vehType.reloadDepots.empty()
                          && route->numTrips() < route->maxTrips();

        auto const clientLoc = U->client();
        if (clientLoc >= data_.numDepots())
        {
            ProblemData::Client const &client = data_.location(clientLoc);
            hasPrize = client.prize > 0;

            // Check if client fits alone in a trip
            for (size_t d = 0;
                 d < data_.numLoadDimensions() && d < vehType.capacity.size();
                 ++d)
            {
                Load clientDemand = 0;
                if (d < client.delivery.size())
                    clientDemand = std::max(clientDemand, client.delivery[d]);
                if (d < client.pickup.size())
                    clientDemand = std::max(clientDemand, client.pickup[d]);

                if (clientDemand > vehType.capacity[d])
                {
                    clientFitsAlone = false;
                    break;
                }
            }
        }

        if (data_.numLoadDimensions() > 0 && !vehType.capacity.empty()
            && canUseMultiTrip)
        {
            if (clientLoc >= data_.numDepots())
            {
                ProblemData::Client const &clientData
                    = data_.location(clientLoc);
                for (size_t d = 0; d < data_.numLoadDimensions()
                                   && d < vehType.capacity.size();
                     ++d)
                {
                    auto const lastClientIdx
                        = route->size() > 2 ? route->size() - 2 : 0;
                    auto const maxIdx = std::min(UAfter->idx(), lastClientIdx);

                    size_t tripStartIdx = 1;
                    for (size_t i = maxIdx; i >= 1; --i)
                    {
                        auto *node = route->operator[](i);
                        if (node->isReloadDepot())
                        {
                            tripStartIdx = i + 1;
                            break;
                        }
                    }

                    Load tripDelivery = 0;
                    Load tripPickup = 0;
                    for (size_t i = tripStartIdx; i <= maxIdx; ++i)
                    {
                        auto *node = route->operator[](i);
                        if (node->client() >= data_.numDepots())
                        {
                            ProblemData::Client const &loc
                                = data_.location(node->client());
                            if (d < loc.delivery.size())
                                tripDelivery = tripDelivery + loc.delivery[d];
                            if (d < loc.pickup.size())
                                tripPickup = tripPickup + loc.pickup[d];
                        }
                    }

                    Load newDelivery = 0;
                    Load newPickup = 0;
                    if (d < clientData.delivery.size())
                        newDelivery = clientData.delivery[d];
                    if (d < clientData.pickup.size())
                        newPickup = clientData.pickup[d];

                    Load startLoad = tripDelivery + newDelivery;
                    Load endLoad = tripPickup + newPickup;
                    Load maxLoad = std::max(startLoad, endLoad);

                    if (maxLoad > vehType.capacity[d])
                    {
                        wouldExceedCapacity = true;
                        break;
                    }
                }
            }
        }
    }

    // DISABLED: Multi-trip insertion override
    //
    // The original intent was to allow inserting clients into a new trip when:
    // 1. The client has a prize (optional client)
    // 2. Multi-trip is available
    // 3. The client would exceed capacity if added to current trip
    //
    // However, this causes infinite loops because:
    // 1. We insert the client with depot split
    // 2. Route becomes infeasible due to TIME constraints (not just capacity)
    // 3. Local search removes the client to improve feasibility
    // 4. Route becomes feasible, we insert again
    //
    // A proper fix would need to:
    // 1. Compute the actual cost INCLUDING time penalties
    // 2. Or perform trial insertion and check feasibility
    // 3. Or track which clients have been tried this iteration
    //
    // For now, multi-trip insertion only happens when bestCost < 0 (i.e., when
    // the standard cost calculation already shows improvement).
    (void)hasPrize;
    (void)clientFitsAlone;

    if (required || bestCost < 0)
    {
        auto *route = UAfter->route();
        auto const &vehType = data_.vehicleType(route->vehicleType());

        if (wouldExceedCapacity && canUseMultiTrip)
        {
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

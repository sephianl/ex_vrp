#include "primitives.h"

#include "Segments.h"

#include <cassert>
#include <limits>

ex_vrp::Cost ex_vrp::search::insertCost(Route::Node *U,
                                        Route::Node *V,
                                        ProblemData const &data,
                                        CostEvaluator const &costEvaluator)
{
    if (!V->route() || U->isDepot())
        return 0;

    auto *route = V->route();
    ProblemData::Client const &client = data.location(U->client());

    Cost deltaCost
        = Cost(route->empty()) * route->fixedVehicleCost() - client.prize;

    costEvaluator.deltaCost<true>(
        deltaCost,
        Route::Proposal(route->before(V->idx()),
                        ClientSegment(data, U->client()),
                        route->after(V->idx() + 1)));

    return deltaCost;
}

ex_vrp::Cost ex_vrp::search::insertTripCost(Route::Node *U,
                                            Route const *route,
                                            size_t depot,
                                            size_t idx,
                                            ProblemData const &data,
                                            CostEvaluator const &costEvaluator)
{
    // Not a move that can be made, so it must never win a `<` comparison
    // against a real delta cost the way a zero would.
    if (!route || U->isDepot())
        return std::numeric_limits<Cost>::max();

    assert(idx >= 1 && idx < route->size());

    ProblemData::Client const &client = data.location(U->client());
    ProblemData::Depot const &depotData = data.location(depot);

    // Reload cost is not part of what deltaCost recomputes, so it is added
    // here the way RelocateWithDepot does.
    Cost deltaCost = Cost(route->empty()) * route->fixedVehicleCost()
                     + depotData.reloadCost - client.prize;

    costEvaluator.deltaCost<true>(
        deltaCost,
        Route::Proposal(route->before(idx - 1),
                        ReloadDepotSegment(data, depot),
                        ClientSegment(data, U->client()),
                        route->after(idx)));

    return deltaCost;
}

ex_vrp::Cost
ex_vrp::search::insertShipmentCost(Route::Node *pickup,
                                   Route::Node *V,
                                   Route::Node *W,
                                   ProblemData const &data,
                                   CostEvaluator const &costEvaluator)
{
    auto *delivery = pickup->partner();
    auto *route = V->route();
    assert(delivery && route && W->route() == route);
    assert(V->idx() <= W->idx() && V->trip() == W->trip());

    ProblemData::Client const &pickupData = data.location(pickup->client());
    ProblemData::Client const &deliveryData = data.location(delivery->client());

    Cost deltaCost = Cost(route->empty()) * route->fixedVehicleCost()
                     - pickupData.prize - deliveryData.prize;

    if (V == W)
        costEvaluator.deltaCost<true>(
            deltaCost,
            Route::Proposal(route->before(V->idx()),
                            ClientSegment(data, pickup->client()),
                            ClientSegment(data, delivery->client()),
                            route->after(V->idx() + 1)));
    else
        costEvaluator.deltaCost<true>(
            deltaCost,
            Route::Proposal(route->before(V->idx()),
                            ClientSegment(data, pickup->client()),
                            route->between(V->idx() + 1, W->idx()),
                            ClientSegment(data, delivery->client()),
                            route->after(W->idx() + 1)));

    return deltaCost;
}

namespace
{
// Delta cost of removing a pickup together with its delivery, both on the
// pickup's route.
ex_vrp::Cost removeShipmentCost(ex_vrp::search::Route::Node *pickup,
                                ex_vrp::ProblemData const &data,
                                ex_vrp::CostEvaluator const &costEvaluator)
{
    using ex_vrp::Cost;
    using ex_vrp::ProblemData;
    using ex_vrp::search::Route;

    auto *delivery = pickup->partner();
    auto *route = pickup->route();
    assert(delivery->route() == route && pickup->idx() < delivery->idx());

    ProblemData::Client const &pickupData = data.location(pickup->client());
    ProblemData::Client const &deliveryData = data.location(delivery->client());

    Cost deltaCost
        = pickupData.prize + deliveryData.prize
          - Cost(route->numClients() == 2) * route->fixedVehicleCost();

    if (pickup->idx() + 1 == delivery->idx())
        costEvaluator.deltaCost<true>(
            deltaCost,
            Route::Proposal(route->before(pickup->idx() - 1),
                            route->after(delivery->idx() + 1)));
    else
        costEvaluator.deltaCost<true>(
            deltaCost,
            Route::Proposal(
                route->before(pickup->idx() - 1),
                route->between(pickup->idx() + 1, delivery->idx() - 1),
                route->after(delivery->idx() + 1)));

    return deltaCost;
}

// Whether the unrouted U may take V's place without its shipment partner.
bool mayArriveAlone(ex_vrp::search::Route::Node const *U,
                    ex_vrp::search::Route::Node const *V,
                    ex_vrp::ProblemData const &data)
{
    auto const *pickup = U->partner();
    if (!pickup || !data.isShipmentDelivery(U->client()))
        return true;

    return pickup->route() == V->route() && pickup->trip() == V->trip()
           && pickup->idx() < V->idx();
}
}  // namespace

ex_vrp::Cost
ex_vrp::search::insertEjectingCost(Route::Node *U,
                                   Route::Node *V,
                                   Route::Node *W,
                                   ProblemData const &data,
                                   CostEvaluator const &costEvaluator)
{
    assert(!U->route() && V->route() && W->route() == V->route() && W != V);

    auto const *route = V->route();
    ProblemData::Client const &uClient = data.location(U->client());
    ProblemData::Client const &wClient = data.location(W->client());
    Cost deltaCost = wClient.prize - uClient.prize;

    if (W->idx() < V->idx())
        costEvaluator.deltaCost<true>(
            deltaCost,
            Route::Proposal(route->before(W->idx() - 1),
                            route->between(W->idx() + 1, V->idx()),
                            ClientSegment(data, U->client()),
                            route->after(V->idx() + 1)));
    else if (W->idx() == V->idx() + 1)
        costEvaluator.deltaCost<true>(
            deltaCost,
            Route::Proposal(route->before(V->idx()),
                            ClientSegment(data, U->client()),
                            route->after(W->idx() + 1)));
    else
        costEvaluator.deltaCost<true>(
            deltaCost,
            Route::Proposal(route->before(V->idx()),
                            ClientSegment(data, U->client()),
                            route->between(V->idx() + 1, W->idx() - 1),
                            route->after(W->idx() + 1)));

    return deltaCost;
}

bool ex_vrp::search::carriesRoutedDelivery(Route::Node *U,
                                           ProblemData const &data)
{
    return U->partner() && U->partner()->route()
           && data.isShipmentPickup(U->client());
}

ex_vrp::Cost ex_vrp::search::removeCost(Route::Node *U,
                                        ProblemData const &data,
                                        CostEvaluator const &costEvaluator)
{
    if (!U->route() || U->isStartDepot() || U->isEndDepot())
        return 0;

    if (carriesRoutedDelivery(U, data))
        return removeShipmentCost(U, data, costEvaluator);

    auto *route = U->route();
    Cost deltaCost = 0;

    if (!U->isDepot())
    {
        ProblemData::Client const &client = data.location(U->client());
        deltaCost
            = client.prize
              - Cost(route->numClients() == 1) * route->fixedVehicleCost();
    }

    costEvaluator.deltaCost<true>(deltaCost,
                                  Route::Proposal(route->before(U->idx() - 1),
                                                  route->after(U->idx() + 1)));

    return deltaCost;
}

ex_vrp::Cost ex_vrp::search::inplaceCost(Route::Node *U,
                                         Route::Node *V,
                                         ProblemData const &data,
                                         CostEvaluator const &costEvaluator)
{
    if (U->route() || !V->route())
        return 0;

    // V leaves alone, so it may not take a routed delivery's pickup away. U
    // arrives alone: a pickup may (its delivery is not routed while it is
    // not), a delivery only after its pickup on the pickup's trip.
    if (carriesRoutedDelivery(V, data) || !mayArriveAlone(U, V, data))
        return 0;

    auto const *route = V->route();
    ProblemData::Client const &uClient = data.location(U->client());
    ProblemData::Client const &vClient = data.location(V->client());

    Cost deltaCost = vClient.prize - uClient.prize;

    costEvaluator.deltaCost<true>(
        deltaCost,
        Route::Proposal(route->before(V->idx() - 1),
                        ClientSegment(data, U->client()),
                        route->after(V->idx() + 1)));

    return deltaCost;
}

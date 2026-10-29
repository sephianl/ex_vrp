#include "RelocateShipment.h"

#include "Route.h"
#include "Segments.h"
#include "primitives.h"

#include <algorithm>
#include <cassert>
#include <limits>

using ex_vrp::search::RelocateShipment;

namespace
{
using ex_vrp::search::Route;

// Whether the profile of route allows both halves of the shipment.
bool allowsBoth(ex_vrp::ProblemData const &data,
                Route const *route,
                Route::Node const *pickup)
{
    if (!data.hasForbiddenLocations())
        return true;

    auto const profile = data.vehicleType(route->vehicleType()).profile;
    return data.isAllowed(profile, pickup->client())
           && data.isAllowed(profile, pickup->partner()->client());
}
}  // namespace

ex_vrp::Cost RelocateShipment::evaluate(Route::Node *U,
                                        Route::Node *V,
                                        CostEvaluator const &costEvaluator)
{
    stats_.numEvaluations++;

    auto *uRoute = U->route();
    auto *vRoute = V->route();

    if (uRoute == vRoute || V->isEndDepot() || !carriesRoutedDelivery(U, data)
        || !allowsBoth(data, vRoute, U))
        return 0;

    auto *delivery = U->partner();
    assert(delivery->route() == uRoute && U->idx() < delivery->idx());

    Cost fixedCost = Cost(vRoute->empty()) * vRoute->fixedVehicleCost();
    if (uRoute->numClients() == 2)
        fixedCost -= uRoute->fixedVehicleCost();

    auto const bestFor = [&](auto const &uProposal)
    {
        auto bestCost = std::numeric_limits<Cost>::max();
        for (auto *W = V;; W = n(W))
        {
            if (!deliveryMayFollow(V, W, delivery->client()))
            {
                if (n(W)->isDepot())
                    return bestCost;

                continue;
            }

            Cost deltaCost = fixedCost;
            if (W == V)
                costEvaluator.deltaCost(
                    deltaCost,
                    uProposal,
                    Route::Proposal(vRoute->before(V->idx()),
                                    ClientSegment(data, U->client()),
                                    ClientSegment(data, delivery->client()),
                                    vRoute->after(V->idx() + 1)));
            else
                costEvaluator.deltaCost(
                    deltaCost,
                    uProposal,
                    Route::Proposal(vRoute->before(V->idx()),
                                    ClientSegment(data, U->client()),
                                    vRoute->between(V->idx() + 1, W->idx()),
                                    ClientSegment(data, delivery->client()),
                                    vRoute->after(W->idx() + 1)));

            if (deltaCost < bestCost)
            {
                bestCost = deltaCost;
                deliveryAfter_ = W;
            }

            if (n(W)->isDepot())
                return bestCost;
        }
    };

    if (U->idx() + 1 == delivery->idx())
        return bestFor(Route::Proposal(uRoute->before(U->idx() - 1),
                                       uRoute->after(delivery->idx() + 1)));

    return bestFor(
        Route::Proposal(uRoute->before(U->idx() - 1),
                        uRoute->between(U->idx() + 1, delivery->idx() - 1),
                        uRoute->after(delivery->idx() + 1)));
}

bool RelocateShipment::deliveryMayFollow(Route::Node const *V,
                                         Route::Node const *W,
                                         size_t delivery) const
{
    auto const &near = neighbours_[delivery];
    return W == V
           || std::find(near.begin(), near.end(), W->client()) != near.end();
}

void RelocateShipment::apply(Route::Node *U, Route::Node *V) const
{
    stats_.numApplications++;

    auto *delivery = U->partner();
    auto *uRoute = U->route();
    auto *vRoute = V->route();
    assert(deliveryAfter_ && deliveryAfter_->route() == vRoute);

    uRoute->remove(delivery->idx());
    uRoute->remove(U->idx());

    vRoute->insert(deliveryAfter_->idx() + 1, delivery);
    vRoute->insert(V->idx() + 1, U);
}

template <>
bool ex_vrp::search::supports<RelocateShipment>(ProblemData const &data)
{
    return data.hasShipments() && data.numVehicles() > 1;
}

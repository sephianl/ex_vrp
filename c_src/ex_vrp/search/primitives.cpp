#include "primitives.h"

#include "Segments.h"

#include <cassert>
#include <limits>

pyvrp::Cost pyvrp::search::insertCost(Route::Node *U,
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

pyvrp::Cost pyvrp::search::insertTripCost(Route::Node *U,
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

pyvrp::Cost pyvrp::search::removeCost(Route::Node *U,
                                      ProblemData const &data,
                                      CostEvaluator const &costEvaluator)
{
    if (!U->route() || U->isStartDepot() || U->isEndDepot())
        return 0;

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

pyvrp::Cost pyvrp::search::inplaceCost(Route::Node *U,
                                       Route::Node *V,
                                       ProblemData const &data,
                                       CostEvaluator const &costEvaluator)
{
    if (U->route() || !V->route())
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

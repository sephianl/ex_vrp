#include "SwapTails.h"

#include "Route.h"

#include <cassert>

using pyvrp::search::SwapTails;

namespace
{
bool onLastTrip(pyvrp::search::Route::Node *node)
{
    auto const *route = node->route();
    return node->trip() + 1 == route->numTrips();
}

// Clients after node, up to the end depot. Breaks there are not clients.
size_t clientsAfter(pyvrp::search::Route::Node *node)
{
    auto const *route = node->route();
    auto const last = route->size() - 2;
    if (node->idx() == last)
        return 0;

    return last - node->idx()
           - route->between(node->idx() + 1, last).numBreaks();
}

// Change in fixed cost when route's tail after `node` becomes `incoming`
// clients: a route that gains its first client pays it, one that loses its
// last is spared it.
pyvrp::Cost fixedCostDelta(pyvrp::search::Route::Node *node, size_t incoming)
{
    auto const *route = node->route();
    auto const before = route->numClients();
    auto const after = before - clientsAfter(node) + incoming;
    return route->fixedVehicleCost()
           * (static_cast<pyvrp::Cost>(after > 0)
              - static_cast<pyvrp::Cost>(before > 0));
}
}  // namespace

pyvrp::Cost SwapTails::evaluate(Route::Node *U,
                                Route::Node *V,
                                CostEvaluator const &costEvaluator)
{
    stats_.numEvaluations++;
    assert(!U->isEndDepot() && !U->isReloadDepot());
    assert(!V->isEndDepot() && !V->isReloadDepot());

    auto const *uRoute = U->route();
    auto const *vRoute = V->route();

    if (uRoute == vRoute)
        return 0;  // same route

    if (uRoute->idx() > vRoute->idx() && !uRoute->empty() && !vRoute->empty())
        return 0;  // move will be tackled in a later iteration

    if (!onLastTrip(U) || !onLastTrip(V))
        // We cannot move reload depots, so we only evaluate a move if it does
        // not include a reload depot.
        return 0;

    Cost deltaCost = 0;

    // We incur fixed cost if a route is currently empty but gains clients,
    // and lose it if a route loses its last client. Breaks in the tails are
    // not clients, so this counts clients rather than asking for depots.
    deltaCost += fixedCostDelta(U, clientsAfter(V));
    deltaCost += fixedCostDelta(V, clientsAfter(U));

    if (!n(U)->isEndDepot() && !n(V)->isEndDepot())
    {
        auto const uProposal
            = Route::Proposal(uRoute->before(U->idx()),
                              vRoute->between(V->idx() + 1, vRoute->size() - 2),
                              uRoute->at(uRoute->size() - 1));

        auto const vProposal
            = Route::Proposal(vRoute->before(V->idx()),
                              uRoute->between(U->idx() + 1, uRoute->size() - 2),
                              vRoute->at(vRoute->size() - 1));

        costEvaluator.deltaCost(deltaCost, uProposal, vProposal);
    }
    else if (!n(U)->isEndDepot() && n(V)->isEndDepot())
    {
        auto const uProposal = Route::Proposal(uRoute->before(U->idx()),
                                               uRoute->at(uRoute->size() - 1));

        auto const vProposal
            = Route::Proposal(vRoute->before(V->idx()),
                              uRoute->between(U->idx() + 1, uRoute->size() - 2),
                              vRoute->at(vRoute->size() - 1));

        costEvaluator.deltaCost(deltaCost, uProposal, vProposal);
    }
    else if (n(U)->isEndDepot() && !n(V)->isEndDepot())
    {
        auto const uProposal
            = Route::Proposal(uRoute->before(U->idx()),
                              vRoute->between(V->idx() + 1, vRoute->size() - 2),
                              uRoute->at(uRoute->size() - 1));

        auto const vProposal = Route::Proposal(vRoute->before(V->idx()),
                                               vRoute->at(vRoute->size() - 1));

        costEvaluator.deltaCost(deltaCost, uProposal, vProposal);
    }

    return deltaCost;
}

void SwapTails::apply(Route::Node *U, Route::Node *V) const
{
    stats_.numApplications++;
    auto *nU = n(U);
    auto *nV = n(V);

    auto insertIdx = U->idx() + 1;
    while (!nV->isEndDepot())
    {
        auto *node = nV;
        nV = n(nV);
        V->route()->remove(node->idx());
        U->route()->insert(insertIdx++, node);
    }

    insertIdx = V->idx() + 1;
    while (!nU->isEndDepot())
    {
        auto *node = nU;
        nU = n(nU);
        U->route()->remove(node->idx());
        V->route()->insert(insertIdx++, node);
    }
}

template <> bool pyvrp::search::supports<SwapTails>(ProblemData const &data)
{
    // Does not work for TSP, since the operator needs at least two routes.
    return data.numVehicles() > 1;
}

#include "SwapTails.h"

#include "Route.h"

#include <cassert>

using ex_vrp::search::SwapTails;

namespace
{
bool onLastTrip(ex_vrp::search::Route::Node *node)
{
    auto const *route = node->route();
    return node->trip() + 1 == route->numTrips();
}

// Clients after node, up to the end depot. Breaks there are not clients.
size_t clientsAfter(ex_vrp::search::Route::Node *node)
{
    auto const *route = node->route();
    auto const last = route->size() - 2;
    if (node->idx() == last || route->numBreaks() == 0)
        return last - node->idx();

    return last - node->idx()
           - route->between(node->idx() + 1, last).numBreaks();
}

// Change in fixed cost when route's tail after `node` becomes `incoming`
// clients: a route that gains its first client pays it, one that loses its
// last is spared it.
ex_vrp::Cost fixedCostDelta(ex_vrp::search::Route::Node *node, size_t incoming)
{
    auto const *route = node->route();
    auto const before = route->numClients();
    auto const after = before - clientsAfter(node) + incoming;
    return route->fixedVehicleCost()
           * (static_cast<ex_vrp::Cost>(after > 0)
              - static_cast<ex_vrp::Cost>(before > 0));
}

// Lower bound on the duration cost of the proposal that keeps `to`'s nodes up
// to and including `cut`, then takes `from`'s tail after `tail` (nothing when
// that is the end depot), and ends at `to`'s end depot: the head's travel and
// service from `to`'s prefix sums, the tail's in `to`'s own profile, and the
// edges joining them. Waiting and depot service only add to a duration.
ex_vrp::Cost tailSwapDurationBound(ex_vrp::ProblemData const &data,
                                   ex_vrp::search::Route::Node *cut,
                                   ex_vrp::search::Route::Node *tail)
{
    using ex_vrp::Duration;
    using ex_vrp::ProblemData;

    auto const *to = cut->route();
    auto const *from = tail->route();
    auto const first = tail->idx() + 1;
    auto const last = from->size() - 2;  // the tail's last client, if any

    // A route left without clients proposes nothing, and costs nothing.
    if (!to->hasDurationBound() || (cut->idx() == 0 && first > last))
        return 0;

    auto const &dur = data.durationMatrix(to->profile());
    auto const toEnd = (*to)[to->size() - 1]->client();

    Duration travel = to->travelTo(cut->idx());
    Duration service = to->clientServiceTo(cut->idx());

    if (first > last)
        travel += dur(cut->client(), toEnd);
    else
    {
        travel += dur(cut->client(), (*from)[first]->client())
                  + dur((*from)[last]->client(), toEnd);

        for (auto idx = first + 1; idx <= last; ++idx)
            travel += dur((*from)[idx - 1]->client(), (*from)[idx]->client());

        service += from->clientService() - from->clientServiceTo(tail->idx());
    }

    return to->unitDurationCost() * static_cast<ex_vrp::Cost>(travel + service);
}
}  // namespace

ex_vrp::Cost SwapTails::evaluate(Route::Node *U,
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
    // and lose it if a route loses its last client. Without breaks on either
    // route every node is a client, so the depots around U and V tell.
    if (uRoute->numBreaks() == 0 && vRoute->numBreaks() == 0)
    {
        if (uRoute->empty() && !n(V)->isEndDepot())
            deltaCost += uRoute->fixedVehicleCost();

        if (vRoute->empty() && !n(U)->isEndDepot())
            deltaCost += vRoute->fixedVehicleCost();

        if (!uRoute->empty() && U->isStartDepot() && n(V)->isEndDepot())
            deltaCost -= uRoute->fixedVehicleCost();

        if (!vRoute->empty() && V->isStartDepot() && n(U)->isEndDepot())
            deltaCost -= vRoute->fixedVehicleCost();
    }
    else  // breaks in the tails are not clients, so count clients instead
    {
        deltaCost += fixedCostDelta(U, clientsAfter(V));
        deltaCost += fixedCostDelta(V, clientsAfter(U));
    }

    // A floor on both proposals' duration, as for Exchange's moves: off with
    // breaks or reloads, which add to a duration in ways it does not track.
    auto const bound
        = !data.hasBreaks() && !uRoute->hasReloads() && !vRoute->hasReloads()
              ? tailSwapDurationBound(data, U, V)
                    + tailSwapDurationBound(data, V, U)
              : 0;

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

        costEvaluator.deltaCost(deltaCost, uProposal, vProposal, bound);
    }
    else if (!n(U)->isEndDepot() && n(V)->isEndDepot())
    {
        auto const uProposal = Route::Proposal(uRoute->before(U->idx()),
                                               uRoute->at(uRoute->size() - 1));

        auto const vProposal
            = Route::Proposal(vRoute->before(V->idx()),
                              uRoute->between(U->idx() + 1, uRoute->size() - 2),
                              vRoute->at(vRoute->size() - 1));

        costEvaluator.deltaCost(deltaCost, uProposal, vProposal, bound);
    }
    else if (n(U)->isEndDepot() && !n(V)->isEndDepot())
    {
        auto const uProposal
            = Route::Proposal(uRoute->before(U->idx()),
                              vRoute->between(V->idx() + 1, vRoute->size() - 2),
                              uRoute->at(uRoute->size() - 1));

        auto const vProposal = Route::Proposal(vRoute->before(V->idx()),
                                               vRoute->at(vRoute->size() - 1));

        costEvaluator.deltaCost(deltaCost, uProposal, vProposal, bound);
    }

    return deltaCost;
}

bool SwapTails::keepsShipments(Route::Node *U, Route::Node *V) const
{
    // Neither cut may separate a pickup from its delivery.
    return !U->route()->carriesShipmentAfter(U->idx())
           && !V->route()->carriesShipmentAfter(V->idx());
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

template <> bool ex_vrp::search::supports<SwapTails>(ProblemData const &data)
{
    // Does not work for TSP, since the operator needs at least two routes.
    return data.numVehicles() > 1;
}

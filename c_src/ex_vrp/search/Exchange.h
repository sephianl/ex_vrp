#ifndef EX_VRP_SEARCH_EXCHANGE_H
#define EX_VRP_SEARCH_EXCHANGE_H

#include "LocalSearchOperator.h"
#include "Route.h"
#include "primitives.h"

#include <cassert>

namespace ex_vrp::search
{
/**
 * Exchange(data: ProblemData)
 *
 * The :math:`(N, M)`-exchange operators exchange :math:`N` consecutive clients
 * from :math:`U`'s route (starting at :math:`U`) with :math:`M` consecutive
 * clients from :math:`V`'s route (starting at :math:`V`). This includes
 * the RELOCATE and SWAP operators as special cases.
 *
 * The :math:`(N, M)`-exchange class uses C++ templates for different :math:`N`
 * and :math:`M` to efficiently evaluate these moves.
 */
template <size_t N, size_t M> class Exchange : public NodeOperator
{
    using NodeOperator::NodeOperator;

    static_assert(N >= M && N > 0, "N < M or N == 0 does not make sense");

    // Tests if the segment starting at node of given length contains the depot
    bool containsDepot(Route::Node *node, size_t segLength) const;

    // Tests if the segments of U and V overlap in the same route
    bool overlap(Route::Node *U, Route::Node *V) const;

    // Tests if the segments of U and V are adjacent in the same route
    bool adjacent(Route::Node *U, Route::Node *V) const;

    // Whether a relocate between these routes can be bounded from below on
    // duration: a route's duration is at least its travel plus its clients'
    // service only while no break or reload depot adds to it in a way this
    // bound does not track.
    bool boundsRelocate(Route const *uRoute, Route const *vRoute) const;

    // Lower bound on the duration cost of the two proposals of relocating U's
    // segment after V in another route: each proposal's travel and client
    // service, from its route's totals and the edges the move cuts and adds.
    Cost relocateDurationBound(Route::Node *U, Route::Node *V) const;

    // The same bound for a relocate within U's route, where service does not
    // change and only the edges around U's segment and V do.
    Cost inRouteRelocateDurationBound(Route::Node *U, Route::Node *V) const;

    // Lower bound on the duration cost of the two proposals of swapping U's
    // segment with V's between two routes: each route trades its own
    // segment's travel and service for the other's, in its own profile.
    Cost swapDurationBound(Route::Node *U, Route::Node *V) const;

    // The same bound for a swap within U's route. Adjacent segments are not
    // swapped, so a stretch of the route always lies between them; service
    // and every segment's inner edges stay, and only the four edges at their
    // ends change.
    Cost inRouteSwapDurationBound(Route::Node *U, Route::Node *V) const;

    // Special case that's applied when M == 0
    Cost evalRelocateMove(Route::Node *U,
                          Route::Node *V,
                          CostEvaluator const &costEvaluator) const;

    // Applied when M != 0
    Cost evalSwapMove(Route::Node *U,
                      Route::Node *V,
                      CostEvaluator const &costEvaluator) const;

public:
    Cost evaluate(Route::Node *U,
                  Route::Node *V,
                  CostEvaluator const &costEvaluator) override;

    void apply(Route::Node *U, Route::Node *V) const override;

    // Within a route, a relocated segment may leave its partners behind as
    // long as every pickup stays first: that is how a pickup or delivery
    // moves on its own. Otherwise moved segments take both halves along.
    bool keepsShipments(Route::Node *U, Route::Node *V) const override;

    size_t spanU() const override { return N; }

    size_t spanV() const override { return M; }
};

template <size_t N, size_t M>
bool Exchange<N, M>::containsDepot(Route::Node *node, size_t segLength) const
{
    auto const first = node->idx();
    auto const last = first + segLength - 1;
    auto const &route = *node->route();

    return first == 0                               // contains start depot
           || last >= route.size() - 1              // contains end depot
           || node->trip() != route[last]->trip();  // contains reload depot
}

template <size_t N, size_t M>
bool Exchange<N, M>::overlap(Route::Node *U, Route::Node *V) const
{
    return U->route() == V->route()
           // We need max(M, 1) here because when V is the depot and M == 0,
           // this would turn negative and wrap around to a large number.
           && U->idx() <= V->idx() + std::max<size_t>(M, 1) - 1
           && V->idx() <= U->idx() + N - 1;
}

template <size_t N, size_t M>
bool Exchange<N, M>::adjacent(Route::Node *U, Route::Node *V) const
{
    return U->route() == V->route()
           && (U->idx() + N == V->idx() || V->idx() + M == U->idx());
}

template <size_t N, size_t M>
bool Exchange<N, M>::keepsShipments(Route::Node *U, Route::Node *V) const
{
    auto const *uRoute = U->route();
    auto const uLast = U->idx() + N - 1;

    if constexpr (M == 0)
        if (uRoute == V->route())
            return uRoute->keepsShipmentOrder(U->idx(), uLast, V->idx());

    if (!uRoute->isShipmentClosed(U->idx(), uLast))
        return false;

    if constexpr (M > 0)
        return V->route()->isShipmentClosed(V->idx(), V->idx() + M - 1);

    return true;
}

template <size_t N, size_t M>
bool Exchange<N, M>::boundsRelocate(Route const *uRoute,
                                    Route const *vRoute) const
{
    return !data.hasBreaks() && !uRoute->hasReloads() && !vRoute->hasReloads();
}

template <size_t N, size_t M>
Cost Exchange<N, M>::relocateDurationBound(Route::Node *U, Route::Node *V) const
{
    auto const *uRoute = U->route();
    auto const *vRoute = V->route();
    auto const &uDur = data.durationMatrix(uRoute->profile());
    auto const &vDur = data.durationMatrix(vRoute->profile());

    auto const first = U->idx();
    auto const *last = (*uRoute)[first + N - 1];
    auto const before = p(U)->client();
    auto const after = n(last)->client();

    Duration service = 0;
    Duration uInner = 0;
    Duration vInner = 0;
    for (size_t idx = first; idx != first + N; ++idx)
    {
        auto const loc = (*uRoute)[idx]->client();
        ProblemData::Client const &client = data.location(loc);
        service += client.serviceDuration;

        if (idx != first)
        {
            auto const prev = (*uRoute)[idx - 1]->client();
            uInner += uDur(prev, loc);
            vInner += vDur(prev, loc);
        }
    }

    Cost bound = 0;

    // A route left without clients proposes nothing, and costs nothing.
    if (uRoute->hasDurationCost() && uRoute->numClients() != N)
    {
        auto const travel = uRoute->travel() - uDur(before, U->client())
                            - uInner - uDur(last->client(), after)
                            + uDur(before, after);
        auto const duration = travel + uRoute->clientService() - service;
        bound += uRoute->unitDurationCost() * static_cast<Cost>(duration);
    }

    if (vRoute->hasDurationCost())
    {
        auto const next = n(V)->client();
        auto const travel = vRoute->travel() - vDur(V->client(), next)
                            + vDur(V->client(), U->client()) + vInner
                            + vDur(last->client(), next);
        auto const duration = travel + vRoute->clientService() + service;
        bound += vRoute->unitDurationCost() * static_cast<Cost>(duration);
    }

    return bound;
}

template <size_t N, size_t M>
Cost Exchange<N, M>::inRouteRelocateDurationBound(Route::Node *U,
                                                  Route::Node *V) const
{
    auto const *route = U->route();
    if (!route->hasDurationCost())
        return 0;

    auto const &dur = data.durationMatrix(route->profile());
    auto const *last = (*route)[U->idx() + N - 1];
    auto const before = p(U)->client();
    auto const after = n(last)->client();
    auto const next = n(V)->client();

    auto const travel = route->travel() - dur(before, U->client())
                        - dur(last->client(), after) + dur(before, after)
                        - dur(V->client(), next) + dur(V->client(), U->client())
                        + dur(last->client(), next);
    auto const duration = travel + route->clientService();
    return route->unitDurationCost() * static_cast<Cost>(duration);
}

template <size_t N, size_t M>
Cost Exchange<N, M>::swapDurationBound(Route::Node *U, Route::Node *V) const
{
    // The proposal of `to` that replaces its segment of `size` nodes from
    // `out` with `from`'s segment of `inSize` nodes from `in`.
    auto const proposalBound = [&](Route const *to,
                                   Route::Node *out,
                                   size_t outSize,
                                   Route const *from,
                                   Route::Node *in,
                                   size_t inSize) -> Cost
    {
        if (!to->hasDurationCost())
            return 0;

        auto const &dur = data.durationMatrix(to->profile());
        auto const *outLast = (*to)[out->idx() + outSize - 1];
        auto const *inLast = (*from)[in->idx() + inSize - 1];
        auto const before = p(out)->client();
        auto const after = n(outLast)->client();

        Duration travel = to->travel() - dur(before, out->client())
                          - dur(outLast->client(), after)
                          + dur(before, in->client())
                          + dur(inLast->client(), after);
        Duration service = to->clientService();

        for (size_t idx = out->idx(); idx != out->idx() + outSize; ++idx)
        {
            auto const loc = (*to)[idx]->client();
            ProblemData::Client const &client = data.location(loc);
            service -= client.serviceDuration;
            if (idx != out->idx())
                travel -= dur((*to)[idx - 1]->client(), loc);
        }

        for (size_t idx = in->idx(); idx != in->idx() + inSize; ++idx)
        {
            auto const loc = (*from)[idx]->client();
            ProblemData::Client const &client = data.location(loc);
            service += client.serviceDuration;
            if (idx != in->idx())
                travel += dur((*from)[idx - 1]->client(), loc);
        }

        return to->unitDurationCost() * static_cast<Cost>(travel + service);
    };

    return proposalBound(U->route(), U, N, V->route(), V, M)
           + proposalBound(V->route(), V, M, U->route(), U, N);
}

template <size_t N, size_t M>
Cost Exchange<N, M>::inRouteSwapDurationBound(Route::Node *U,
                                              Route::Node *V) const
{
    auto const *route = U->route();
    if (!route->hasDurationCost())
        return 0;

    // The earlier segment and the later one, whichever of U's and V's each is.
    auto const uFirst = U->idx() < V->idx();
    auto *first = uFirst ? U : V;
    auto *second = uFirst ? V : U;
    auto const firstSize = uFirst ? N : M;
    auto const secondSize = uFirst ? M : N;

    auto const &dur = data.durationMatrix(route->profile());
    auto const firstEnd = (*route)[first->idx() + firstSize - 1]->client();
    auto const secondEnd = (*route)[second->idx() + secondSize - 1]->client();
    auto const before = p(first)->client();
    auto const after = (*route)[second->idx() + secondSize]->client();
    auto const midStart = (*route)[first->idx() + firstSize]->client();
    auto const midEnd = p(second)->client();

    auto const travel = route->travel() - dur(before, first->client())
                        - dur(firstEnd, midStart)
                        - dur(midEnd, second->client()) - dur(secondEnd, after)
                        + dur(before, second->client())
                        + dur(secondEnd, midStart)
                        + dur(midEnd, first->client()) + dur(firstEnd, after);
    auto const duration = travel + route->clientService();
    return route->unitDurationCost() * static_cast<Cost>(duration);
}

template <size_t N, size_t M>
Cost Exchange<N, M>::evalRelocateMove(Route::Node *U,
                                      Route::Node *V,
                                      CostEvaluator const &costEvaluator) const
{
    assert(U->idx() > 0);

    Cost deltaCost = 0;

    if (U->route() != V->route())
    {
        auto const *uRoute = U->route();
        auto const *vRoute = V->route();

        // We're going to incur V's fixed cost if V is currently empty.
        if (V->isStartDepot() && vRoute->empty())
            deltaCost += vRoute->fixedVehicleCost();

        // We lose U's fixed cost if we're moving all U's clients. The N nodes
        // may carry breaks, which are not clients.
        auto const moved = uRoute->between(U->idx(), U->idx() + N - 1);
        if (uRoute->numClients() == N - moved.numBreaks())
            deltaCost -= uRoute->fixedVehicleCost();

        auto const uProposal = Route::Proposal(uRoute->before(U->idx() - 1),
                                               uRoute->after(U->idx() + N));

        auto const vProposal
            = Route::Proposal(vRoute->before(V->idx()),
                              uRoute->between(U->idx(), U->idx() + N - 1),
                              vRoute->after(V->idx() + 1));

        auto const bound
            = boundsRelocate(uRoute, vRoute) ? relocateDurationBound(U, V) : 0;
        costEvaluator.deltaCost(deltaCost, uProposal, vProposal, bound);
    }
    else  // within same route
    {
        auto *route = U->route();
        auto const bound = boundsRelocate(route, route)
                               ? inRouteRelocateDurationBound(U, V)
                               : 0;

        if (U->idx() < V->idx())
            costEvaluator.deltaCost(
                deltaCost,
                Route::Proposal(route->before(U->idx() - 1),
                                route->between(U->idx() + N, V->idx()),
                                route->between(U->idx(), U->idx() + N - 1),
                                route->after(V->idx() + 1)),
                bound);
        else
            costEvaluator.deltaCost(
                deltaCost,
                Route::Proposal(route->before(V->idx()),
                                route->between(U->idx(), U->idx() + N - 1),
                                route->between(V->idx() + 1, U->idx() - 1),
                                route->after(U->idx() + N)),
                bound);
    }

    return deltaCost;
}

template <size_t N, size_t M>
Cost Exchange<N, M>::evalSwapMove(Route::Node *U,
                                  Route::Node *V,
                                  CostEvaluator const &costEvaluator) const
{
    assert(U->idx() > 0 && V->idx() > 0);
    assert(U->route() && V->route());

    Cost deltaCost = 0;

    if (U->route() != V->route())
    {
        auto const *uRoute = U->route();
        auto const *vRoute = V->route();

        auto const uProposal
            = Route::Proposal(uRoute->before(U->idx() - 1),
                              vRoute->between(V->idx(), V->idx() + M - 1),
                              uRoute->after(U->idx() + N));

        auto const vProposal
            = Route::Proposal(vRoute->before(V->idx() - 1),
                              uRoute->between(U->idx(), U->idx() + N - 1),
                              vRoute->after(V->idx() + M));

        auto const bound
            = boundsRelocate(uRoute, vRoute) ? swapDurationBound(U, V) : 0;
        costEvaluator.deltaCost(deltaCost, uProposal, vProposal, bound);
    }
    else  // within same route
    {
        auto const *route = U->route();
        auto const bound
            = boundsRelocate(route, route) ? inRouteSwapDurationBound(U, V) : 0;

        if (U->idx() < V->idx())
            costEvaluator.deltaCost(
                deltaCost,
                Route::Proposal(route->before(U->idx() - 1),
                                route->between(V->idx(), V->idx() + M - 1),
                                route->between(U->idx() + N, V->idx() - 1),
                                route->between(U->idx(), U->idx() + N - 1),
                                route->after(V->idx() + M)),
                bound);
        else
            costEvaluator.deltaCost(
                deltaCost,
                Route::Proposal(route->before(V->idx() - 1),
                                route->between(U->idx(), U->idx() + N - 1),
                                route->between(V->idx() + M, U->idx() - 1),
                                route->between(V->idx(), V->idx() + M - 1),
                                route->after(U->idx() + N)),
                bound);
    }

    return deltaCost;
}

template <size_t N, size_t M>
Cost Exchange<N, M>::evaluate(Route::Node *U,
                              Route::Node *V,
                              CostEvaluator const &costEvaluator)
{
    stats_.numEvaluations++;

    if (containsDepot(U, N) || overlap(U, V))
        return 0;

    if constexpr (M > 0)
        if (containsDepot(V, M))
            return 0;

    // We cannot easily evaluate across trips, so we cannot determine this move.
    if (U->route() == V->route() && U->trip() != V->trip())
        return 0;

    if constexpr (M == 0)  // special case where nothing in V is moved
    {
        if (U == n(V))
            return 0;

        return evalRelocateMove(U, V, costEvaluator);
    }
    else
    {
        if constexpr (N == M)  // symmetric, so only have to evaluate this once
            if (U->client() >= V->client())
                return 0;

        if (adjacent(U, V))
            return 0;

        return evalSwapMove(U, V, costEvaluator);
    }
}

template <size_t N, size_t M>
void Exchange<N, M>::apply(Route::Node *U, Route::Node *V) const
{
    stats_.numApplications++;

    auto &uRoute = *U->route();
    auto &vRoute = *V->route();
    auto *uToInsert = N == 1 ? U : uRoute[U->idx() + N - 1];
    auto *insertUAfter = M == 0 ? V : vRoute[V->idx() + M - 1];

    // Insert these 'extra' nodes of U after the end of V...
    for (size_t count = 0; count != N - M; ++count)
    {
        auto *prev = p(uToInsert);
        uRoute.remove(uToInsert->idx());
        vRoute.insert(insertUAfter->idx() + 1, uToInsert);
        uToInsert = prev;
    }

    // ...and swap the overlapping nodes!
    for (size_t count = 0; count != M; ++count)
    {
        Route::swap(U, V);
        U = n(U);
        V = n(V);
    }
}
}  // namespace ex_vrp::search

#endif  // EX_VRP_SEARCH_EXCHANGE_H

#ifndef EX_VRP_SEARCH_RELOCATESHIPMENT_H
#define EX_VRP_SEARCH_RELOCATESHIPMENT_H

#include "LocalSearchOperator.h"
#include "SearchSpace.h"

namespace ex_vrp::search
{
/**
 * RelocateShipment(data: ProblemData, neighbours: Neighbours)
 *
 * Given a pickup :math:`U` whose delivery is on the same route, and a node
 * :math:`V` on another route, tests moving the pickup to directly after
 * :math:`V` and its delivery to directly after the pickup, or after a later
 * node of :math:`V`'s trip that neighbours the delivery. Applies the best of
 * those.
 *
 * Exchange moves a shipment between routes only when both halves sit within
 * one moved segment; this operator moves them wherever they are. Within a
 * route, Exchange moves either half on its own.
 */
class RelocateShipment : public NodeOperator
{
    // The local search's granular neighbourhood, which it may replace.
    SearchSpace::Neighbours const &neighbours_;

    // Node in V's route to insert the delivery after, of the move last
    // evaluated.
    Route::Node *deliveryAfter_ = nullptr;

    // Whether the delivery may go directly after W, when the pickup goes
    // directly after V.
    bool deliveryMayFollow(Route::Node const *V,
                           Route::Node const *W,
                           size_t delivery) const;

public:
    RelocateShipment(ProblemData const &data,
                     SearchSpace::Neighbours const &neighbours)
        : NodeOperator(data), neighbours_(neighbours)
    {
    }

    Cost evaluate(Route::Node *U,
                  Route::Node *V,
                  CostEvaluator const &costEvaluator) override;

    void apply(Route::Node *U, Route::Node *V) const override;

    // V stays where it is; evaluate() checks both halves may join V's route.
    size_t spanV() const override { return 0; }
};

template <> bool supports<RelocateShipment>(ProblemData const &data);
}  // namespace ex_vrp::search

#endif  // EX_VRP_SEARCH_RELOCATESHIPMENT_H

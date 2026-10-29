#ifndef EX_VRP_SEARCH_SWAPTAILS_H
#define EX_VRP_SEARCH_SWAPTAILS_H

#include "LocalSearchOperator.h"

namespace ex_vrp::search
{
/**
 * SwapTails(data: ProblemData)
 *
 * Given two nodes :math:`U` and :math:`V`, tests whether replacing the arc of
 * :math:`U` to its successor :math:`n(U)` and :math:`V` to :math:`n(V)` by
 * :math:`U \rightarrow n(V)` and :math:`V \rightarrow n(U)` is an improving
 * move.
 *
 * .. note::
 *
 *    This operator is also known as 2-OPT* in the VRP literature.
 */
class SwapTails : public NodeOperator
{
    using NodeOperator::NodeOperator;

public:
    Cost evaluate(Route::Node *U,
                  Route::Node *V,
                  CostEvaluator const &costEvaluator) override;

    void apply(Route::Node *U, Route::Node *V) const override;

    bool affectsEntireTail() const override { return true; }

    bool keepsShipments(Route::Node *U, Route::Node *V) const override;
};

template <> bool supports<SwapTails>(ProblemData const &data);
}  // namespace ex_vrp::search

#endif  // EX_VRP_SEARCH_SWAPTAILS_H

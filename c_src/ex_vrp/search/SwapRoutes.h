#ifndef EX_VRP_SEARCH_SWAPROUTES_H
#define EX_VRP_SEARCH_SWAPROUTES_H

#include "LocalSearchOperator.h"
#include "SwapTails.h"

namespace ex_vrp::search
{
/**
 * SwapRoutes(data: ProblemData)
 *
 * This operator evaluates exchanging the visits of two routes :math:`U` and
 * :math:`V`.
 */
class SwapRoutes : public RouteOperator
{
    SwapTails op;

public:
    Cost
    evaluate(Route *U, Route *V, CostEvaluator const &costEvaluator) override;

    void apply(Route *U, Route *V) const override;

    explicit SwapRoutes(ProblemData const &data);
};

template <> bool supports<SwapRoutes>(ProblemData const &data);
}  // namespace ex_vrp::search

#endif  // EX_VRP_SEARCH_SWAPROUTES_H

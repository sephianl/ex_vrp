#ifndef PYVRP_SEARCH_SWAPROUTES_H
#define PYVRP_SEARCH_SWAPROUTES_H

#include "LocalSearchOperator.h"
#include "SwapTails.h"

namespace pyvrp::search
{
/**
 * SwapRoutes(data: ProblemData)
 *
 * This operator evaluates exchanging the visits of two routes :math:`U` and
 * :math:`V`. Takes the start depot nodes of each route as arguments.
 */
class SwapRoutes : public BinaryOperator
{
    SwapTails op;

public:
    std::pair<Cost, bool> evaluate(Route::Node *U,
                                   Route::Node *V,
                                   CostEvaluator const &costEvaluator) override;

    void apply(Route::Node *U, Route::Node *V) const override;

    explicit SwapRoutes(ProblemData const &data);
};

template <> bool supports<SwapRoutes>(ProblemData const &data);
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_SWAPROUTES_H

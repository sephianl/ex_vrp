#ifndef PYVRP_SEARCH_REMOVEADJACENTDEPOT_H
#define PYVRP_SEARCH_REMOVEADJACENTDEPOT_H

#include "LocalSearchOperator.h"
#include "Route.h"

namespace pyvrp::search
{
class RemoveAdjacentDepot : public UnaryOperator
{
    using UnaryOperator::UnaryOperator;

    mutable Route::Node *depotToRemove_ = nullptr;

public:
    std::pair<Cost, bool> evaluate(Route::Node *U,
                                   CostEvaluator const &costEvaluator) override;

    void apply(Route::Node *U) const override;
};

template <> bool supports<RemoveAdjacentDepot>(ProblemData const &data);
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_REMOVEADJACENTDEPOT_H

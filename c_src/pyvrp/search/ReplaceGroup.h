#ifndef PYVRP_SEARCH_REPLACEGROUP_H
#define PYVRP_SEARCH_REPLACEGROUP_H

#include "LocalSearchOperator.h"
#include "Route.h"

namespace pyvrp::search
{
class Solution;

class ReplaceGroup : public UnaryOperator
{
    Solution *solution_ = nullptr;
    mutable Route::Node *bestTarget_ = nullptr;

public:
    using UnaryOperator::UnaryOperator;

    void init(Solution &solution) override;

    std::pair<Cost, bool> evaluate(Route::Node *U,
                                   CostEvaluator const &costEvaluator) override;

    void apply(Route::Node *U) const override;
};

template <> bool supports<ReplaceGroup>(ProblemData const &data);
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_REPLACEGROUP_H

#ifndef PYVRP_SEARCH_REPLACEOPTIONAL_H
#define PYVRP_SEARCH_REPLACEOPTIONAL_H

#include "LocalSearchOperator.h"
#include "Route.h"
#include "SearchSpace.h"

#include <vector>

namespace pyvrp::search
{
class Solution;

class ReplaceOptional : public UnaryOperator
{
    SearchSpace const &searchSpace_;
    Solution *solution_ = nullptr;
    mutable Route::Node *bestTarget_ = nullptr;
    std::vector<std::vector<size_t>> sameVehicleGroups_;

    bool hasSameVehicleMemberOnRoute(size_t client, Route const *route) const;

public:
    ReplaceOptional(ProblemData const &data, SearchSpace const &searchSpace);

    void init(Solution &solution) override;

    std::pair<Cost, bool> evaluate(Route::Node *U,
                                   CostEvaluator const &costEvaluator) override;

    void apply(Route::Node *U) const override;
};

template <> bool supports<ReplaceOptional>(ProblemData const &data);
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_REPLACEOPTIONAL_H

#ifndef PYVRP_SEARCH_REMOVEOPTIONAL_H
#define PYVRP_SEARCH_REMOVEOPTIONAL_H

#include "LocalSearchOperator.h"
#include "Route.h"

#include <vector>

namespace pyvrp::search
{
class Solution;

class RemoveOptional : public UnaryOperator
{
    Solution *solution_ = nullptr;
    std::vector<std::vector<size_t>> sameVehicleGroups_;

    bool hasSameVehicleMemberOnRoute(size_t client, Route const *route) const;

public:
    RemoveOptional(ProblemData const &data);

    void init(Solution &solution) override;

    std::pair<Cost, bool> evaluate(Route::Node *U,
                                   CostEvaluator const &costEvaluator) override;

    void apply(Route::Node *U) const override;
};

template <> bool supports<RemoveOptional>(ProblemData const &data);
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_REMOVEOPTIONAL_H

#include "ReplaceGroup.h"

#include "ClientSegment.h"
#include "Route.h"
#include "Solution.h"

using pyvrp::Cost;
using pyvrp::search::ReplaceGroup;

void ReplaceGroup::init(Solution &solution)
{
    UnaryOperator::init(solution);
    solution_ = &solution;
}

std::pair<Cost, bool> ReplaceGroup::evaluate(Route::Node *U,
                                             CostEvaluator const &costEvaluator)
{
    stats_.numEvaluations++;

    ProblemData::Client const &uData
        = data.client(U->client() - data.numDepots());
    if (!uData.group)
        return {0, false};

    auto const &group = data.group(*uData.group);

    Route::Node *activeV = nullptr;
    size_t numInSol = 0;
    for (auto const client : group)
    {
        if (solution_->nodes[client].route())
        {
            numInSol++;
            activeV = &solution_->nodes[client];
        }
    }

    if (numInSol != 1 || !activeV || activeV == U)
        return {0, false};

    ProblemData::Client const &uClient
        = data.client(U->client() - data.numDepots());
    ProblemData::Client const &vClient
        = data.client(activeV->client() - data.numDepots());

    auto const *route = activeV->route();
    Cost deltaCost = vClient.prize - uClient.prize;
    costEvaluator.deltaCost<true>(
        deltaCost,
        Route::Proposal(route->before(activeV->idx() - 1),
                        ClientSegment(data, U->client()),
                        route->after(activeV->idx() + 1)));

    bestTarget_ = activeV;
    return {deltaCost, deltaCost < 0};
}

void ReplaceGroup::apply(Route::Node *U) const
{
    stats_.numApplications++;
    auto *route = bestTarget_->route();
    auto const idx = bestTarget_->idx();
    route->remove(idx);
    route->insert(idx, U);
}

template <> bool pyvrp::search::supports<ReplaceGroup>(ProblemData const &data)
{
    return data.numGroups() > 0;
}

#include "ReplaceOptional.h"

#include "ClientSegment.h"
#include "Route.h"
#include "Solution.h"

using pyvrp::Cost;
using pyvrp::search::ReplaceOptional;

ReplaceOptional::ReplaceOptional(ProblemData const &data,
                                 SearchSpace const &searchSpace)
    : UnaryOperator(data), searchSpace_(searchSpace)
{
    sameVehicleGroups_.resize(data.numLocations());
    for (size_t g = 0; g < data.numSameVehicleGroups(); ++g)
        for (auto client : data.sameVehicleGroup(g))
            sameVehicleGroups_[client].push_back(g);
}

void ReplaceOptional::init(Solution &solution)
{
    UnaryOperator::init(solution);
    solution_ = &solution;
}

bool ReplaceOptional::hasSameVehicleMemberOnRoute(size_t client,
                                                  Route const *route) const
{
    for (auto g : sameVehicleGroups_[client])
    {
        auto const &group = data.sameVehicleGroup(g);
        for (auto member : group)
        {
            if (member == client)
                continue;
            if (solution_->nodes[member].route() == route)
                return true;
        }
    }
    return false;
}

std::pair<Cost, bool>
ReplaceOptional::evaluate(Route::Node *U, CostEvaluator const &costEvaluator)
{
    stats_.numEvaluations++;

    if (U->route())
        return {0, false};

    ProblemData::Client const &uData
        = data.client(U->client() - data.numDepots());
    if (uData.required || uData.group)
        return {0, false};

    bestTarget_ = nullptr;
    auto bestCost = Cost(0);

    for (auto const vClient : searchSpace_.neighboursOf(U->client()))
    {
        auto *V = &solution_->nodes[vClient];
        auto *route = V->route();

        if (!route)
            continue;

        ProblemData::Client const &vData
            = data.client(V->client() - data.numDepots());
        if (vData.required || vData.group)
            continue;

        if (hasSameVehicleMemberOnRoute(V->client(), route))
            continue;

        Cost deltaCost = vData.prize - uData.prize;
        costEvaluator.deltaCost<true>(
            deltaCost,
            Route::Proposal(route->before(V->idx() - 1),
                            ClientSegment(data, U->client()),
                            route->after(V->idx() + 1)));

        if (deltaCost < bestCost)
        {
            bestCost = deltaCost;
            bestTarget_ = V;
        }
    }

    if (!bestTarget_)
        return {0, false};

    return {bestCost, bestCost < 0};
}

void ReplaceOptional::apply(Route::Node *U) const
{
    stats_.numApplications++;
    auto *route = bestTarget_->route();
    auto const idx = bestTarget_->idx();
    route->remove(idx);
    route->insert(idx, U);
}

template <>
bool pyvrp::search::supports<ReplaceOptional>(ProblemData const &data)
{
    for (size_t idx = data.numDepots(); idx != data.numLocations(); ++idx)
    {
        ProblemData::Client const &client = data.client(idx - data.numDepots());
        if (!client.required && !client.group)
            return true;
    }
    return false;
}

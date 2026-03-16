#include "RemoveOptional.h"

#include "Route.h"
#include "Solution.h"

using pyvrp::Cost;
using pyvrp::search::RemoveOptional;

RemoveOptional::RemoveOptional(ProblemData const &data) : UnaryOperator(data)
{
    sameVehicleGroups_.resize(data.numLocations());
    for (size_t g = 0; g < data.numSameVehicleGroups(); ++g)
        for (auto client : data.sameVehicleGroup(g))
            sameVehicleGroups_[client].push_back(g);
}

void RemoveOptional::init(Solution &solution)
{
    UnaryOperator::init(solution);
    solution_ = &solution;
}

bool RemoveOptional::hasSameVehicleMemberOnRoute(size_t client,
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
RemoveOptional::evaluate(Route::Node *U, CostEvaluator const &costEvaluator)
{
    stats_.numEvaluations++;

    if (!U->route() || U->isDepot())
        return {0, false};

    ProblemData::Client const &uData
        = data.client(U->client() - data.numDepots());
    if (uData.required || uData.group)
        return {0, false};

    if (hasSameVehicleMemberOnRoute(U->client(), U->route()))
        return {0, false};

    auto *route = U->route();
    Cost deltaCost
        = uData.prize
          - Cost(route->numClients() == 1) * route->fixedVehicleCost();

    costEvaluator.deltaCost<true>(deltaCost,
                                  Route::Proposal(route->before(U->idx() - 1),
                                                  route->after(U->idx() + 1)));

    return {deltaCost, deltaCost < 0};
}

void RemoveOptional::apply(Route::Node *U) const
{
    stats_.numApplications++;
    U->route()->remove(U->idx());
}

template <>
bool pyvrp::search::supports<RemoveOptional>(ProblemData const &data)
{
    for (size_t idx = data.numDepots(); idx != data.numLocations(); ++idx)
    {
        ProblemData::Client const &client = data.client(idx - data.numDepots());
        if (!client.required && !client.group)
            return true;
    }
    return false;
}

#include "RemoveAdjacentDepot.h"

#include "Route.h"

#include <cassert>

using pyvrp::Cost;
using pyvrp::search::RemoveAdjacentDepot;

namespace
{
pyvrp::Cost evalRemoveCost(pyvrp::search::Route::Node *U,
                           pyvrp::ProblemData const &data,
                           pyvrp::CostEvaluator const &costEvaluator)
{
    if (!U->route() || U->isStartDepot() || U->isEndDepot())
        return 0;

    auto *route = U->route();
    pyvrp::Cost deltaCost = 0;

    if (!U->isDepot())
    {
        pyvrp::ProblemData::Client const &client = data.location(U->client());
        deltaCost = client.prize
                    - pyvrp::Cost(route->numClients() == 1)
                          * route->fixedVehicleCost();
    }

    costEvaluator.deltaCost<true>(
        deltaCost,
        pyvrp::search::Route::Proposal(route->before(U->idx() - 1),
                                       route->after(U->idx() + 1)));

    return deltaCost;
}
}  // namespace

std::pair<Cost, bool>
RemoveAdjacentDepot::evaluate(Route::Node *U,
                              CostEvaluator const &costEvaluator)
{
    stats_.numEvaluations++;
    depotToRemove_ = nullptr;

    if (!U->route())
        return {0, false};

    Cost bestCost = 0;

    auto *pU = p(U);
    if (pU->isReloadDepot())
    {
        auto const cost = evalRemoveCost(pU, data, costEvaluator);
        if (cost <= 0)
        {
            bestCost = cost;
            depotToRemove_ = pU;
        }
    }

    auto *nU = n(U);
    if (nU->isReloadDepot())
    {
        auto const cost = evalRemoveCost(nU, data, costEvaluator);
        if (cost < bestCost || (cost <= 0 && !depotToRemove_))
        {
            bestCost = cost;
            depotToRemove_ = nU;
        }
    }

    if (!depotToRemove_)
        return {0, false};

    return {bestCost, true};
}

void RemoveAdjacentDepot::apply([[maybe_unused]] Route::Node *U) const
{
    stats_.numApplications++;
    assert(depotToRemove_ && depotToRemove_->isReloadDepot());
    depotToRemove_->route()->remove(depotToRemove_->idx());
}

template <>
bool pyvrp::search::supports<RemoveAdjacentDepot>(ProblemData const &data)
{
    for (auto const &vehType : data.vehicleTypes())
        if (!vehType.reloadDepots.empty() && vehType.maxReloads != 0)
            return true;

    return false;
}

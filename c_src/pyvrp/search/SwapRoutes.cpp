#include "SwapRoutes.h"

using pyvrp::Cost;
using pyvrp::search::SwapRoutes;

std::pair<Cost, bool> SwapRoutes::evaluate(Route::Node *U,
                                           Route::Node *V,
                                           CostEvaluator const &costEvaluator)
{
    stats_.numEvaluations++;

    auto *routeU = U->route();
    auto *routeV = V->route();

    if (routeU == routeV || routeU->vehicleType() == routeV->vehicleType())
        return {0, false};

    return op.evaluate(U, V, costEvaluator);
}

void SwapRoutes::apply(Route::Node *U, Route::Node *V) const
{
    stats_.numApplications++;
    op.apply(U, V);
}

SwapRoutes::SwapRoutes(ProblemData const &data) : BinaryOperator(data), op(data)
{
}

template <> bool pyvrp::search::supports<SwapRoutes>(ProblemData const &data)
{
    return data.numVehicleTypes() > 1;
}

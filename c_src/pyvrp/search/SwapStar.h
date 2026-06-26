#ifndef PYVRP_SEARCH_SWAPSTAR_H
#define PYVRP_SEARCH_SWAPSTAR_H

#include "LocalSearchOperator.h"
#include "Matrix.h"

#include <array>
#include <utility>

namespace pyvrp::search
{
/**
 * SwapStar(data: ProblemData, overlap_tolerance: float = 0.05)
 *
 * Explores the SWAP* neighbourhood of [1]_. The SWAP* neighbourhood consists
 * of free form re-insertions of clients :math:`U` and :math:`V` in the given
 * routes (so the clients are swapped, but they are not necessarily inserted
 * in the place of the other swapped client).
 *
 * This is a route-level operator that does not fit the node-based operator
 * interface. It is called directly by LocalSearch::intensify().
 *
 * References
 * ----------
 * .. [1] Thibaut Vidal. 2022. Hybrid genetic search for the CVRP: Open-source
 *        implementation and SWAP* neighborhood. *Comput. Oper. Res*. 140.
 *        https://doi.org/10.1016/j.cor.2021.105643
 */
class SwapStar
{
    using InsertPoint = std::pair<Cost, Route::Node *>;
    using ThreeBest = std::array<InsertPoint, 3>;

    struct BestMove
    {
        Cost cost = 0;

        Route::Node *U = nullptr;
        Route::Node *UAfter = nullptr;

        Route::Node *V = nullptr;
        Route::Node *VAfter = nullptr;
    };

    ProblemData const &data;
    mutable OperatorStatistics stats_;

    double const overlapTolerance;

    Matrix<ThreeBest> insertCache;
    Matrix<bool> isCached;
    Matrix<Cost> removalCosts;

    BestMove best;

    void updateRemovalCosts(Route *R, CostEvaluator const &costEvaluator);

    void updateInsertPoints(Route *R,
                            Route::Node *U,
                            CostEvaluator const &costEvaluator);

    Cost deltaLoadCost(Route::Node *U,
                       Route::Node *V,
                       CostEvaluator const &costEvaluator) const;

    InsertPoint bestInsertPoint(Route::Node *U,
                                Route::Node *V,
                                CostEvaluator const &costEvaluator);

    Cost evaluateMove(Route::Node const *U,
                      Route::Node const *V,
                      Route::Node const *remove,
                      CostEvaluator const &costEvaluator) const;

public:
    void init();

    Cost evaluate(Route *U, Route *V, CostEvaluator const &costEvaluator);

    void apply(Route *U, Route *V) const;

    void update(Route *U);

    OperatorStatistics const &statistics() const { return stats_; }

    explicit SwapStar(ProblemData const &data, double overlapTolerance = 0.05);
};
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_SWAPSTAR_H

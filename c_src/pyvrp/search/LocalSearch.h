#ifndef PYVRP_SEARCH_LOCALSEARCH_H
#define PYVRP_SEARCH_LOCALSEARCH_H

#include "CostEvaluator.h"
#include "LocalSearchOperator.h"
#include "PerturbationManager.h"
#include "ProblemData.h"
#include "RandomNumberGenerator.h"
#include "Route.h"
#include "SearchSpace.h"
#include "Solution.h"  // pyvrp::search::Solution

#include <chrono>
#include <functional>
#include <stdexcept>
#include <vector>

namespace pyvrp::search
{
class LocalSearch
{
    ProblemData const &data;

    Solution solution_;

    SearchSpace searchSpace_;

    PerturbationManager &perturbationManager_;

    std::vector<UnaryOperator *> unaryOps;
    std::vector<BinaryOperator *> binaryOps;

    std::vector<int> lastTestedNodes;
    std::vector<int> lastUpdated;

    std::vector<std::vector<size_t>> clientToSameVehicleGroups_;

    size_t numUpdates_ = 0;
    bool searchCompleted_ = false;

    std::chrono::steady_clock::time_point timeout_deadline_;
    bool has_timeout_ = false;

    void loadSolution(pyvrp::Solution const &solution);

    void applyUnaryOps(Route::Node *U, CostEvaluator const &costEvaluator);

    bool applyBinaryOps(Route::Node *U,
                        Route::Node *V,
                        CostEvaluator const &costEvaluator);

    void applyEmptyRouteMoves(Route::Node *U,
                              CostEvaluator const &costEvaluator);

    bool wouldViolateSameVehicle(Route::Node const *U,
                                 Route const *targetRoute) const;

    void applyOptionalClientMoves(Route::Node *U,
                                  CostEvaluator const &costEvaluator);

    void applyGroupMoves(Route::Node *U, CostEvaluator const &costEvaluator);

    void applyDepotRemovalMove(Route::Node *U,
                               CostEvaluator const &costEvaluator);

    bool wouldViolateForbidden(Route::Node const *U,
                               Route const *targetRoute) const;

    bool isHardToPlace(Route::Node const *U) const;

    void applySameVehicleRepair(Route::Node *U,
                                CostEvaluator const &costEvaluator);

    bool wouldTailSwapSplitSVG(Route::Node const *U,
                               Route::Node const *V) const;

    void update(Route *U, Route *V);

    void search(CostEvaluator const &costEvaluator);

    void ensureStructuralFeasibility(CostEvaluator const &costEvaluator);

    void insertConstrainedFirst(CostEvaluator const &costEvaluator);

    void improveWithMultiTrip(CostEvaluator const &costEvaluator);

public:
    struct Statistics
    {
        size_t const numMoves;
        size_t const numImproving;
        size_t const numUpdates;
    };

    void addOperator(BinaryOperator &op);

    void addOperator(UnaryOperator &op);

    std::vector<BinaryOperator *> const &operators() const;

    void setNeighbours(SearchSpace::Neighbours neighbours);

    SearchSpace::Neighbours const &neighbours() const;

    SearchSpace const &searchSpace() const;

    Statistics statistics() const;

    pyvrp::Solution operator()(pyvrp::Solution const &solution,
                               CostEvaluator const &costEvaluator,
                               bool exhaustive = false,
                               int64_t timeout_ms = 0);

    pyvrp::Solution search(pyvrp::Solution const &solution,
                           CostEvaluator const &costEvaluator,
                           int64_t timeout_ms = 0);

    void shuffle(RandomNumberGenerator &rng);

    LocalSearch(ProblemData const &data,
                SearchSpace::Neighbours neighbours,
                PerturbationManager &perturbationManager);
};
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_LOCALSEARCH_H

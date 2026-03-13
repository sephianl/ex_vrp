#ifndef PYVRP_SEARCH_LOCALSEARCHOPERATOR_H
#define PYVRP_SEARCH_LOCALSEARCHOPERATOR_H

#include "CostEvaluator.h"
#include "Measure.h"
#include "ProblemData.h"
#include "Route.h"

#include <type_traits>
#include <utility>

namespace pyvrp::search
{
class Solution;

/**
 * Simple data structure that tracks statistics about the number of times
 * an operator was evaluated and applied.
 *
 * Attributes
 * ----------
 * num_evaluations
 *     Number of evaluated moves.
 * num_applications
 *     Number of applied, improving moves.
 */
struct OperatorStatistics
{
    size_t numEvaluations = 0;
    size_t numApplications = 0;
};

template <typename... Args> class LocalSearchOperator
{
    static_assert((std::is_same_v<Args, Route::Node *> && ...),
                  "All operator arguments must be Route::Node *");

protected:
    ProblemData const &data;
    mutable OperatorStatistics stats_;

public:
    /**
     * Determines the cost delta of applying this operator to the arguments.
     * Returns a pair of (delta cost, applied). If the cost delta is negative,
     * this is an improving move. The bool indicates whether the operator has
     * already applied the move during evaluation.
     * <br />
     * The contract is as follows: if the cost delta is negative, that is the
     * true cost delta of this move. As such, improving moves are fully
     * evaluated. The operator, however, is free to return early if it knows
     * the move will never be good: that is, when it determines the cost delta
     * cannot become negative at all. In that case, the returned (non-negative)
     * cost delta does not constitute a full evaluation.
     */
    virtual std::pair<Cost, bool> evaluate(Args... args,
                                           CostEvaluator const &costEvaluator)
        = 0;

    /**
     * Applies this operator to the given arguments. For improvements, should
     * only be called if <code>evaluate()</code> returns a negative delta cost
     * and the move was not already applied during evaluation.
     */
    virtual void apply(Args... args) const = 0;

    /**
     * Called once after loading the solution to improve. This can be used to
     * e.g. update local operator state.
     */
    virtual void init([[maybe_unused]] Solution &solution)
    {
        stats_ = {};  // reset call statistics
    };

    /**
     * Called when a route has been changed. Can be used to update caches, but
     * the implementation should be fast: this is called every time something
     * changes! Default implementation does nothing.
     */
    virtual void update([[maybe_unused]] Route *U) {}

    /**
     * Returns evaluation and application statistics collected since the last
     * solution initialisation.
     */
    OperatorStatistics const &statistics() const { return stats_; }

    LocalSearchOperator(ProblemData const &data) : data(data) {};
    virtual ~LocalSearchOperator() = default;
};

/**
 * Unary operator: operates on a single node.
 */
using UnaryOperator = LocalSearchOperator<Route::Node *>;

/**
 * Binary operator: operates on a pair of nodes.
 */
using BinaryOperator = LocalSearchOperator<Route::Node *, Route::Node *>;

/**
 * Backward compatibility alias (temporary).
 */
using NodeOperator = BinaryOperator;

/**
 * Helper template function that may be specialised to determine if an operator
 * can find improving moves for the given data instance.
 */
template <typename Op> bool supports([[maybe_unused]] ProblemData const &data)
{
    return true;
}
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_LOCALSEARCHOPERATOR_H

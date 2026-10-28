#ifndef EX_VRP_SEARCH_PRIMITIVES_H
#define EX_VRP_SEARCH_PRIMITIVES_H

#include "CostEvaluator.h"
#include "Measure.h"
#include "Route.h"

// This file stores a few basic functions for (precisely) evaluating really
// common moves. Those primitives may be useful implementing higher order
// operators.
namespace ex_vrp::search
{
/**
 * Evaluates the delta cost of inserting U after V in V's route. The evaluation
 * is exact.
 *
 * Parameters
 * ----------
 * U
 *     Node to insert.
 * V
 *     Node to insert U after. Must be in a route.
 * data
 *     Problem data instance.
 * cost_evaluator
 *     Cost evaluator to use.
 *
 * Returns
 * -------
 * int
 *     Exact delta cost of inserting U after V.
 */
Cost insertCost(Route::Node *U,
                Route::Node *V,
                ProblemData const &data,
                CostEvaluator const &costEvaluator);

/**
 * Evaluates the delta cost of opening a new trip in the given route: a reload
 * depot inserted at idx, and U directly after it. The evaluation is exact.
 *
 * Parameters
 * ----------
 * U
 *     Node to insert. Must not be a depot.
 * route
 *     Route to open the new trip in.
 * depot
 *     Reload depot to open the new trip at.
 * idx
 *     Index the reload depot is inserted at, so that the resulting route is
 *     the nodes before idx, then the depot, then U, then the nodes from idx.
 * data
 *     Problem data instance.
 * cost_evaluator
 *     Cost evaluator to use.
 *
 * Returns
 * -------
 * int
 *     Exact delta cost of opening the new trip, reload cost included.
 */
Cost insertTripCost(Route::Node *U,
                    Route const *route,
                    size_t depot,
                    size_t idx,
                    ProblemData const &data,
                    CostEvaluator const &costEvaluator);

/**
 * Evaluates the delta cost of inserting U in the place of V. The evaluation is
 * exact.
 *
 * Parameters
 * ----------
 * U
 *     Node to insert. Must not be in a route.
 * V
 *     Node to insert U in place of. Must be in a route.
 * data
 *     Problem data instance.
 * cost_evaluator
 *     Cost evaluator to use.
 *
 * Returns
 * -------
 * int
 *     Exact delta cost of inserting U in place of V.
 */
Cost inplaceCost(Route::Node *U,
                 Route::Node *V,
                 ProblemData const &data,
                 CostEvaluator const &costEvaluator);

/**
 * Evaluates inserting U after V while removing W from V's route, to make room
 * for U. The evaluation is exact.
 *
 * Parameters
 * ----------
 * U
 *     Node to insert. Must not be in a route.
 * V
 *     Node to insert U after. Must be in a route.
 * W
 *     Client to remove, on V's route and not V itself.
 * data
 *     Problem data instance.
 * cost_evaluator
 *     Cost evaluator to use.
 *
 * Returns
 * -------
 * int
 *     Exact delta cost of inserting U after V and removing W.
 */
Cost insertEjectingCost(Route::Node *U,
                        Route::Node *V,
                        Route::Node *W,
                        ProblemData const &data,
                        CostEvaluator const &costEvaluator);

/**
 * Evaluates inserting a shipment's pickup directly after V and its delivery
 * directly after W, both in V's route. W is V, for the delivery to follow the
 * pickup at once, or a later node in V's trip. The evaluation is exact, and
 * includes both prizes.
 *
 * Parameters
 * ----------
 * pickup
 *     Pickup node to insert; its partner is the delivery. Neither may be in a
 *     route.
 * V
 *     Node to insert the pickup after. Must be in a route.
 * W
 *     Node to insert the delivery after: V, or a later node of V's trip.
 * data
 *     Problem data instance.
 * cost_evaluator
 *     Cost evaluator to use.
 */
Cost insertShipmentCost(Route::Node *pickup,
                        Route::Node *V,
                        Route::Node *W,
                        ProblemData const &data,
                        CostEvaluator const &costEvaluator);

/**
 * Whether U is a shipment pickup whose delivery is on a route. Removing U
 * then removes the delivery too: it may not be visited without its pickup.
 */
bool carriesRoutedDelivery(Route::Node *U, ProblemData const &data);

/**
 * Evaluates removing U from its current route. The evaluation is exact. A
 * pickup whose delivery is routed is removed together with that delivery
 * (see carriesRoutedDelivery).
 *
 * Parameters
 * ----------
 * U
 *     Node to remove (client or reload depot). Must currently be in a route.
 * data
 *     Problem data instance.
 * cost_evaluator
 *     Cost evaluator to use.
 *
 * Returns
 * -------
 * int
 *     Exact delta cost of removing U.
 */
Cost removeCost(Route::Node *U,
                ProblemData const &data,
                CostEvaluator const &costEvaluator);
}  // namespace ex_vrp::search

#endif  // EX_VRP_SEARCH_PRIMITIVES_H

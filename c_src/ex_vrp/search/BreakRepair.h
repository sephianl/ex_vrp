#ifndef PYVRP_SEARCH_BREAKREPAIR_H
#define PYVRP_SEARCH_BREAKREPAIR_H

#include "CostEvaluator.h"
#include "DriveClock.h"
#include "ProblemData.h"
#include "Route.h"
#include "Solution.h"

#include <vector>

namespace pyvrp::search
{
/**
 * Places break clients on a single route. A break has no location, so the
 * granular neighbourhoods cannot propose one; this pass does instead.
 *
 * Insert: while the route's clock overruns, try a free break on the leg where
 * either clock's stretch first passes its limit, and on up to two earlier legs
 * of that stretch (an earlier leg may absorb waiting), and apply the best if
 * its delta is negative. A leg whose own drive overruns the stretch it opens
 * gets all the breaks it needs at once: a single break there only moves the
 * overrun into the stretch after it, so one at a time would never improve.
 *
 * Remove: drop each break whose removal does not raise the cost. A break that
 * costs nothing to lose is not needed, and only lengthens the route.
 */
class BreakRepair
{
    // A leg to try: the real node it leaves, and how many breaks to add so
    // that the leg's own drive no longer overruns the stretch it opens.
    struct Candidate
    {
        size_t from;
        size_t count;
    };

    ProblemData const &data;
    std::vector<size_t> breaks_;             // every break client
    std::vector<Candidate> candidates_;      // scratch, per insert
    std::vector<Route::Node *> freeBreaks_;  // scratch, per insert

    // Adds the legs a break could go on for the given clock's first overrun.
    template <ClockQuantity Quantity> void addCandidates(Route const &route);

    // Fills freeBreaks_ with up to count breaks not on any route.
    void collectFreeBreaks(Solution &solution, size_t count);

    bool insertBreak(Route &route,
                     Solution &solution,
                     CostEvaluator const &costEvaluator);

    bool removeBreaks(Route &route, CostEvaluator const &costEvaluator) const;

public:
    explicit BreakRepair(ProblemData const &data);

    /**
     * Whether the instance has any break clients. Without them, apply() never
     * changes anything.
     */
    [[nodiscard]] bool hasBreaks() const;

    /**
     * Inserts and removes breaks on the given (updated) route, leaving it
     * updated. Returns whether anything changed.
     */
    bool
    apply(Route &route, Solution &solution, CostEvaluator const &costEvaluator);
};
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_BREAKREPAIR_H

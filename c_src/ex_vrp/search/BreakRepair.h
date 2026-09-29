#ifndef PYVRP_SEARCH_BREAKREPAIR_H
#define PYVRP_SEARCH_BREAKREPAIR_H

#include "CostEvaluator.h"
#include "DriveClock.h"
#include "ProblemData.h"
#include "Route.h"
#include "Solution.h"

#include <array>
#include <vector>

namespace pyvrp::search
{
/**
 * Places break clients on a single route. A break has no location, so the
 * granular neighbourhoods cannot propose one; this pass does instead.
 *
 * The search prices a stretch that overruns its clock as the breaks it lacks
 * (see Route::virtualBreaks()), so moves are not rejected for wanting a break.
 * This pass turns those virtual breaks into real ones, and the solution the
 * search hands back is truthful: an overrun left in place is time warp there.
 *
 * Materialise: while the route's true clock overrun is positive, try free
 * breaks on the legs of every overrunning stretch, walking on as if the
 * overrunning leg took its breaks, and apply the cheapest proposal that
 * lowers the true overrun, whatever its delta: a virtual break costs about
 * what a real one does, so waiting for an improving delta would leave the
 * overrun in place. A leg whose own drive overruns the stretch it opens gets
 * all the breaks it needs at once: a single break there only moves the
 * overrun into the stretch after it.
 *
 * Release: drop each break whose removal neither raises the true overrun nor
 * the cost, and every break on a route without clients or a break rule.
 * Materialising only while overrun is positive, and releasing only what adds
 * none, cannot undo one another.
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

    // Legs of the open stretch offered at an overrun, most recent first.
    static constexpr size_t MAX_LEGS_PER_OVERRUN = 6;

    ProblemData const &data;
    std::vector<size_t> breaks_;             // every break client
    std::vector<Candidate> candidates_;      // scratch, per insert
    std::vector<Route::Node *> freeBreaks_;  // scratch, per insert

    // Adds the legs a break could go on for each of the clock's overruns.
    template <ClockQuantity Quantity> void addCandidates(Route const &route);

    // Fills freeBreaks_ with up to count breaks not on any route.
    void collectFreeBreaks(Solution &solution, size_t count);

    bool insertBreak(Route &route,
                     Solution &solution,
                     CostEvaluator const &costEvaluator);

    bool stripBreaks(Route &route) const;

    bool removeRedundant(Route &route,
                         CostEvaluator const &costEvaluator) const;

public:
    explicit BreakRepair(ProblemData const &data);

    /**
     * Whether the instance has any break clients. Without them, release() and
     * apply() never change anything.
     */
    [[nodiscard]] bool hasBreaks() const;

    /**
     * Removes the breaks the given (updated) route does not need, leaving it
     * updated, so they are free for apply() on other routes. Returns whether
     * anything changed.
     */
    bool release(Route &route, CostEvaluator const &costEvaluator) const;

    /**
     * Materialises the breaks the given (updated) route lacks, then releases
     * any that became redundant, leaving it updated. Returns whether anything
     * changed.
     */
    bool
    apply(Route &route, Solution &solution, CostEvaluator const &costEvaluator);
};
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_BREAKREPAIR_H

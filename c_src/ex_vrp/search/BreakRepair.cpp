#include "BreakRepair.h"

#include "Segments.h"

#include <algorithm>
#include <array>
#include <limits>

using pyvrp::search::BreakRepair;
using pyvrp::search::Route;

BreakRepair::BreakRepair(ProblemData const &data) : data(data)
{
    for (size_t client = data.numDepots(); client != data.numLocations();
         ++client)
        if (data.isBreak(client))
            breaks_.push_back(client);
}

bool BreakRepair::hasBreaks() const { return !breaks_.empty(); }

template <pyvrp::ClockQuantity Quantity>
void BreakRepair::addCandidates(Route const &route)
{
    auto const limit = route.vehicleTypeData().breakLimit(Quantity);
    if (limit == std::numeric_limits<Duration>::max())
        return;

    auto const &durations = data.durationMatrix(route.profile());

    // The open stretch's legs, oldest first. Only the most recent ones are
    // candidates, so older ones fall off the front.
    std::array<Candidate, MAX_LEGS_PER_OVERRUN> legs = {};
    size_t numLegs = 0;

    // The walk applies the search's rule leg by leg: a leg carrying k >= 1
    // breaks closes the stretch before it, and the next one starts with what
    // is left of its drive after (k - 1) * limit is pre-paid.
    auto stretch = route.template clockAt<Quantity>(0);
    size_t from = 0;    // the real node the current leg leaves
    size_t breaks = 0;  // breaks on the current leg
    for (size_t idx = 1; idx != route.size(); ++idx)
    {
        if (data.isBreak(route[idx]->client()))
        {
            ++breaks;
            continue;
        }

        auto const drive = durations(route.location(from), route.location(idx));
        auto const own = route.template clockAt<Quantity>(idx);
        auto const afterPrepaid = [&](size_t onLeg)
        {
            auto const prepaid = static_cast<Duration>(onLeg - 1) * limit;
            return (drive > prepaid ? drive - prepaid : Duration(0)) + own;
        };

        if (breaks == 0)
            stretch += drive + own;
        else
        {
            stretch = afterPrepaid(breaks);
            numLegs = 0;
        }

        if (numLegs == legs.size())
        {
            std::shift_left(legs.begin(), legs.end(), 1);
            numLegs--;
        }

        // Breaks the leg needs in all so that what its drive leaves after the
        // pre-paid ones, plus the arrival's own quantity, fits the limit (or
        // leaves only that quantity, when it alone does not).
        auto const room = limit > own ? limit - own : Duration(0);
        auto const excess = drive > room ? (drive - room).get() : 0;
        auto const needed  // 1 + ceil(excess / limit)
            = 1 + static_cast<size_t>((excess + limit.get() - 1) / limit.get());
        auto const count = needed > breaks ? needed - breaks : 1;
        legs[numLegs++] = {from, count};

        if (stretch > limit)  // the leg into idx is where it overruns, so it
        {                     // is tried first, then the earlier ones
            for (size_t leg = numLegs; leg-- != 0;)
                candidates_.push_back(legs[leg]);

            // Walk on as if this leg took its breaks, so the stretches after
            // it offer candidates too.
            stretch = afterPrepaid(breaks + count);
            numLegs = 0;
        }

        from = idx;
        breaks = 0;
    }
}

void BreakRepair::collectFreeBreaks(Solution &solution, size_t count)
{
    freeBreaks_.clear();
    for (auto const client : breaks_)
    {
        if (freeBreaks_.size() == count)
            return;

        if (!solution.nodes[client].route())
            freeBreaks_.push_back(&solution.nodes[client]);
    }
}

bool BreakRepair::insertBreak(Route &route,
                              Solution &solution,
                              CostEvaluator const &costEvaluator)
{
    candidates_.clear();
    addCandidates<ClockQuantity::Drive>(route);
    addCandidates<ClockQuantity::Work>(route);

    size_t maxCount = 0;
    for (auto const &candidate : candidates_)
        maxCount = std::max(maxCount, candidate.count);

    collectFreeBreaks(solution, maxCount);
    if (freeBreaks_.empty())
        return false;

    // The breaks are interchangeable, so one prices the whole run.
    auto const client = freeBreaks_.front()->client();
    auto const overrun = route.totalClockExcess();

    auto bestCost = std::numeric_limits<Cost>::max();
    Candidate best = {0, 0};  // count 0: no candidate lowers the overrun
    for (auto const &[from, wanted] : candidates_)
    {
        auto const count = std::min(wanted, freeBreaks_.size());
        Route::Proposal const proposal(route.before(from),
                                       BreakSegment(data, client, count),
                                       route.after(from + 1));

        auto const after
            = proposal.driveClockOverrun() + proposal.workClockOverrun();
        if (after >= overrun)
            continue;

        Cost deltaCost = 0;
        costEvaluator.deltaCost<true>(deltaCost, proposal);

        if (deltaCost < bestCost)
        {
            bestCost = deltaCost;
            best = {from, count};
        }
    }

    if (best.count == 0)
        return false;

    for (size_t idx = 0; idx != best.count; ++idx)
        route.insert(best.from + 1, freeBreaks_[idx]);

    route.update();
    return true;
}

bool BreakRepair::stripBreaks(Route &route) const
{
    bool changed = false;

    // Backwards, so a removal leaves the indices still to visit in place.
    for (size_t idx = route.size() - 1; idx-- > 1;)
        if (data.isBreak(route[idx]->client()))
        {
            route.remove(idx);
            changed = true;
        }

    if (changed)
        route.update();

    return changed;
}

bool BreakRepair::removeRedundant(Route &route,
                                  CostEvaluator const &costEvaluator) const
{
    bool changed = false;

    // Backwards, so a removal leaves the indices still to visit in place.
    for (size_t idx = route.size() - 1; idx-- > 1;)
    {
        if (!data.isBreak(route[idx]->client()))
            continue;

        Route::Proposal const proposal(route.before(idx - 1),
                                       route.after(idx + 1));

        auto const after
            = proposal.driveClockOverrun() + proposal.workClockOverrun();
        if (after > route.totalClockExcess())
            continue;

        Cost deltaCost = 0;
        costEvaluator.deltaCost<true>(deltaCost, proposal);

        if (deltaCost <= 0)
        {
            route.remove(idx);
            route.update();
            changed = true;
        }
    }

    return changed;
}

bool BreakRepair::release(Route &route,
                          CostEvaluator const &costEvaluator) const
{
    if (!route.vehicleTypeData().hasBreakRule() || route.empty())
        return stripBreaks(route);

    return removeRedundant(route, costEvaluator);
}

bool BreakRepair::apply(Route &route,
                        Solution &solution,
                        CostEvaluator const &costEvaluator)
{
    if (!route.vehicleTypeData().hasBreakRule() || route.empty())
        return stripBreaks(route);

    bool changed = false;

    // Each insert lowers the true overrun and takes a break from the finite
    // pool, so this terminates.
    while (route.totalClockExcess() > 0
           && insertBreak(route, solution, costEvaluator))
        changed = true;

    return removeRedundant(route, costEvaluator) || changed;
}

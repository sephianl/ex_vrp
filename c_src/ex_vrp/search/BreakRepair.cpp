#include "BreakRepair.h"

#include "Segments.h"

#include <algorithm>
#include <array>
#include <limits>

using ex_vrp::search::BreakRepair;
using ex_vrp::search::Route;

BreakRepair::BreakRepair(ProblemData const &data) : data(data)
{
    for (size_t client = data.numDepots(); client != data.numLocations();
         ++client)
        if (data.isRest(client))
            rests_.push_back(client);
        else if (data.isBreak(client))
            breaks_.push_back(client);
}

bool BreakRepair::hasBreaks() const
{
    return !breaks_.empty() || !rests_.empty();
}

void BreakRepair::addCandidates(Route const &route)
{
    auto const limits = route.vehicleTypeData().breakLimits();
    auto const &durations = data.durationMatrix(route.profile());

    // The open stretch's legs, oldest first. Only the most recent ones are
    // candidates, so older ones fall off the front.
    std::array<Candidate, MAX_LEGS_PER_OVERRUN> legs = {};
    size_t numLegs = 0;

    // The walk applies the search's rule leg by leg, over both clocks at once
    // (BreakPlacement): a leg carrying k >= 1 breaks closes the stretches it
    // continues at its first break, and the next ones start with what the leg
    // leaves.
    auto drive = route.clockAt<ClockQuantity::Drive>(0);
    auto work = route.clockAt<ClockQuantity::Work>(0);
    size_t from = 0;    // the real node the current leg leaves
    size_t breaks = 0;  // breaks on the current leg
    bool rest = false;  // whether one of them is a rest
    for (size_t idx = 1; idx != route.size(); ++idx)
    {
        if (data.isBreak(route[idx]->client()))
        {
            ++breaks;
            rest = rest || data.isRest(route[idx]->client());
            continue;
        }

        auto const edge = durations(route.location(from), route.location(idx));
        auto const ownDrive = route.clockAt<ClockQuantity::Drive>(idx);
        auto const ownWork = route.clockAt<ClockQuantity::Work>(idx);
        auto const leg
            = BreakPlacement::along(drive, work, edge, limits).withRest(rest);
        auto const left = [&, continued = drive](size_t onLeg)
        { return DriveClock::acrossBreaks(continued, edge, onLeg, leg).after; };

        if (breaks == 0)
        {
            drive += edge + ownDrive;
            work += edge + ownWork;
        }
        else
        {
            drive = left(breaks) + ownDrive;
            work = left(breaks) + ownWork;
            numLegs = 0;
        }

        if (numLegs == legs.size())
        {
            std::shift_left(legs.begin(), legs.end(), 1);
            numLegs--;
        }

        // Breaks the leg needs in all so that, on each clock, what its travel
        // leaves after the first break's share and each further spacing, plus
        // the arrival's own quantity, fits the limit (or leaves only that
        // quantity, when it alone does not).
        auto const needed = [&](Duration own, Duration limit)
        {
            auto const room = limit > own ? limit - own : Duration(0);
            auto const excess = left(1) > room ? (left(1) - room).get() : 0;
            auto const spacing = leg.spacing.get();
            return 1 + static_cast<size_t>((excess + spacing - 1) / spacing);
        };

        auto const all = std::max(needed(ownDrive, limits.drive),
                                  needed(ownWork, limits.work));
        auto const count = all > breaks ? all - breaks : 1;
        legs[numLegs++] = {from, count};

        // The leg into idx is where a clock overruns, so it is tried first,
        // then the earlier ones.
        if (drive > limits.drive || work > limits.work)
        {
            for (size_t candidate = numLegs; candidate-- != 0;)
                candidates_.push_back(legs[candidate]);

            // Walk on as if this leg took its breaks, so the stretches after
            // it offer candidates too.
            drive = left(breaks + count) + ownDrive;
            work = left(breaks + count) + ownWork;
            numLegs = 0;
        }

        from = idx;
        breaks = 0;
        rest = false;
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
    addCandidates(route);

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

        auto const after = proposal.clockOverrun();
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

Route::Node *BreakRepair::freeRest(Solution &solution) const
{
    for (auto const client : rests_)
        if (!solution.nodes[client].route())
            return &solution.nodes[client];

    return nullptr;
}

bool BreakRepair::insertRest(Route &route,
                             Solution &solution,
                             CostEvaluator const &costEvaluator)
{
    auto *rest = freeRest(solution);
    if (!rest)
        return false;

    // A rest is taken where the vehicle is, so it goes right after a located
    // node; the travel on its leg is driven after it. Every such leg of the
    // route is tried: routes with rests are few, and their duty prefixes make
    // each proposal cheap.
    // The rest that lowers the overrun most wins, the cheapest among equals:
    // it ends a period where the period runs out, so the next one starts
    // fresh. The cheapest alone favours a rest early in a long period, which
    // leaves the rest of it to need another, and a route ends up resting
    // after nearly every visit.
    auto const overrun = route.totalDutyExcess();
    auto bestExcess = overrun;
    auto bestCost = std::numeric_limits<Cost>::max();
    size_t best = 0;  // 0: no leg lowers the overrun
    for (size_t from = 0; from + 1 < route.size(); ++from)
    {
        if (data.isBreak(route[from]->client()))
            continue;

        Route::Proposal const proposal(route.before(from),
                                       BreakSegment(data, rest->client()),
                                       route.after(from + 1));

        auto const excess = proposal.dutyCost().excess;
        if (excess >= overrun || excess > bestExcess)
            continue;

        Cost deltaCost = 0;
        costEvaluator.deltaCost<true>(deltaCost, proposal);

        if (excess < bestExcess || deltaCost < bestCost)
        {
            bestExcess = excess;
            bestCost = deltaCost;
            best = from + 1;
        }
    }

    if (best == 0)
        return false;

    route.insert(best, rest);
    route.update();
    return true;
}

bool BreakRepair::isRedundant(Route const &route, size_t idx) const
{
    Route::Proposal const proposal(route.before(idx - 1), route.after(idx + 1));

    return proposal.clockOverrun() <= route.totalClockExcess()
           && proposal.dutyCost().excess <= route.totalDutyExcess();
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
    auto const placesRests = route.vehicleTypeData().hasRestRule();
    for (size_t idx = route.size() - 1; idx-- > 1;)
    {
        auto const client = route[idx]->client();
        if (!data.isBreak(client) || (data.isRest(client) && !placesRests))
            continue;

        if (!isRedundant(route, idx))
            continue;

        Route::Proposal const proposal(route.before(idx - 1),
                                       route.after(idx + 1));

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

    // Each insert lowers the true overrun and takes a rest or break from the
    // finite pool, so this terminates. Rests go first: they reset the clocks.
    if (route.vehicleTypeData().hasRestRule())
        while (route.totalDutyExcess() > 0
               && insertRest(route, solution, costEvaluator))
            changed = true;

    while (route.totalClockExcess() > 0
           && insertBreak(route, solution, costEvaluator))
        changed = true;

    return removeRedundant(route, costEvaluator) || changed;
}

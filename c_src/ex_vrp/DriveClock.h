#ifndef PYVRP_DRIVECLOCK_H
#define PYVRP_DRIVECLOCK_H

#include "Measure.h"

#include <algorithm>
#include <cstddef>

namespace pyvrp
{
/**
 * What a clock counts. Drive: edge travel only. Work: edge travel plus each
 * node's service (client service, reload-depot service). Waiting is neither.
 */
enum class ClockQuantity
{
    Drive,
    Work
};

/**
 * Driving (or work) since the last break, folded over a segment the way
 * TripDistance is folded over trips. Breaks belong to legs, and are taken
 * along them as late as the limit allows (see acrossBreaks()). A real node
 * doing q of the quantity itself is {q, 0, q}.
 *
 * How much of a leg fits before its first break depends on the stretch it
 * continues, so merge() is exact only when that stretch is whole: when first
 * starts where the route does, and second has no reset of its own. A segment
 * with resets extends a clock by walking them instead (search::Route's
 * extendClock()), which is why the folds run from the route's start.
 *
 * Alongside the clipped overrun it counts the breaks the stretches still
 * lack, ceil(stretch / limit) - 1 each: what the search prices a stretch that
 * no break covers yet as, before BreakRepair places real ones.
 */
struct DriveClock
{
    Duration head = 0;    // drive before the first internal reset
    Duration excess = 0;  // clipped overrun of stretches wholly inside
    Duration tail = 0;    // drive after the last internal reset
    size_t resets = 0;    // internal legs carrying breaks
    size_t leadRun = 0;   // breaks before the first real node
    size_t trailRun = 0;  // breaks after the last real node
    size_t need = 0;      // breaks lacking in stretches wholly inside

    bool operator==(DriveClock const &other) const = default;

    [[nodiscard]] static Duration clip(Duration drive, Duration limit)
    {
        return drive > limit ? drive - limit : 0;
    }

    [[nodiscard]] static size_t needOf(Duration drive, Duration limit)
    {
        return drive > limit
                   ? static_cast<size_t>((drive.get() - 1) / limit.get())
                   : 0;
    }

    // What a leg carrying breaks leaves either side of them.
    struct BreakLeg
    {
        Duration closed;  // the stretch its first break closes
        Duration after;   // its drive left after its last break
    };

    // A leg of `drive` carrying `breaks` >= 1, continuing a stretch of
    // `stretch`. The first break comes once the stretch reaches the limit, or
    // at the leg's end if it does not, and each further one after another
    // limit of the leg's drive. Where a break falls along its leg changes no
    // time, only the clock. Only call with a finite limit.
    [[nodiscard]] static BreakLeg acrossBreaks(Duration stretch,
                                               Duration drive,
                                               size_t breaks,
                                               Duration limit)
    {
        auto const room = stretch < limit ? limit - stretch : Duration(0);
        auto const before = std::min(drive, room);
        auto const left = drive - before;
        auto const prepaid = static_cast<Duration>(breaks - 1) * limit;
        return {stretch + before, left > prepaid ? left - prepaid : 0};
    }

    // Only call with a finite limit: (onLeg - 1) * limit must not overflow.
    [[nodiscard]] static DriveClock merge(DriveClock const &first,
                                          Duration edge,
                                          DriveClock const &second,
                                          Duration limit)
    {
        auto const onLeg = first.trailRun + second.leadRun;

        DriveClock out;
        out.leadRun = first.leadRun;
        out.trailRun = second.trailRun;

        if (onLeg == 0)
        {
            auto const mid = first.tail + edge + second.head;
            out.head = first.resets ? first.head : mid;
            out.tail = second.resets ? second.tail : mid;
            out.resets = first.resets + second.resets;
            auto const closesMid = first.resets && second.resets;
            out.excess = first.excess + second.excess
                         + (closesMid ? clip(mid, limit) : 0);
            out.need = first.need + second.need
                       + (closesMid ? needOf(mid, limit) : 0);
            return out;
        }

        auto const leg = acrossBreaks(first.tail, edge, onLeg, limit);
        auto const after = leg.after + second.head;

        out.head = first.resets ? first.head : leg.closed;
        out.tail = second.resets ? second.tail : after;
        out.resets = first.resets + second.resets + 1;
        out.excess = first.excess + second.excess
                     + (first.resets ? clip(leg.closed, limit) : 0)
                     + (second.resets ? clip(after, limit) : 0);
        out.need = first.need + second.need
                   + (first.resets ? needOf(leg.closed, limit) : 0)
                   + (second.resets ? needOf(after, limit) : 0);
        return out;
    }

    // Overrun of a closed route, whose ends are real depots.
    [[nodiscard]] Duration overrun(Duration limit) const
    {
        return excess + clip(head, limit) + (resets ? clip(tail, limit) : 0);
    }

    // Breaks a closed route still lacks, stretch by stretch like overrun().
    [[nodiscard]] size_t missing(Duration limit) const
    {
        return need + needOf(head, limit) + (resets ? needOf(tail, limit) : 0);
    }
};
}  // namespace pyvrp

#endif  // PYVRP_DRIVECLOCK_H

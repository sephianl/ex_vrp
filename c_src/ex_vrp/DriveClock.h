#ifndef PYVRP_DRIVECLOCK_H
#define PYVRP_DRIVECLOCK_H

#include "Measure.h"

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
 * TripDistance is folded over trips. Breaks belong to legs: a leg carrying
 * k >= 1 breaks resets the clock at its start and pre-pays (k - 1) * limit of
 * its own drive. A real node doing q of the quantity itself is {q, 0, q}.
 */
struct DriveClock
{
    Duration head = 0;    // drive before the first internal reset
    Duration excess = 0;  // clipped overrun of stretches wholly inside
    Duration tail = 0;    // drive after the last internal reset
    size_t resets = 0;    // internal legs carrying breaks
    size_t leadRun = 0;   // breaks before the first real node
    size_t trailRun = 0;  // breaks after the last real node

    bool operator==(DriveClock const &other) const = default;

    [[nodiscard]] static Duration clip(Duration drive, Duration limit)
    {
        return drive > limit ? drive - limit : 0;
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
            out.excess
                = first.excess + second.excess
                  + (first.resets && second.resets ? clip(mid, limit) : 0);
            return out;
        }

        auto const prepaid = static_cast<Duration>(onLeg - 1) * limit;
        auto const after = (edge > prepaid ? edge - prepaid : 0) + second.head;

        out.head = first.head;
        out.tail = second.resets ? second.tail : after;
        out.resets = first.resets + second.resets + 1;
        out.excess = first.excess + second.excess
                     + (first.resets ? clip(first.tail, limit) : 0)
                     + (second.resets ? clip(after, limit) : 0);
        return out;
    }

    // Overrun of a closed route, whose ends are real depots.
    [[nodiscard]] Duration overrun(Duration limit) const
    {
        return excess + clip(head, limit) + (resets ? clip(tail, limit) : 0);
    }
};
}  // namespace pyvrp

#endif  // PYVRP_DRIVECLOCK_H

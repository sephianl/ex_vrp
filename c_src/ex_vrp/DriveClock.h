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

// The two clocks' limits; max() leaves a clock unbounded.
struct BreakLimits
{
    Duration drive;
    Duration work;

    template <ClockQuantity Quantity> [[nodiscard]] Duration of() const
    {
        return Quantity == ClockQuantity::Drive ? drive : work;
    }
};

/**
 * Where a leg's breaks fall: the first `before` into the leg, each further
 * one `spacing` after the last. Travel adds to both clocks alike, so one
 * placement serves both, and a break resets both where it falls.
 */
struct BreakPlacement
{
    Duration before;
    Duration spacing;

    // A leg of `edge`, continuing stretches of `drive` and `work`. Its first
    // break comes where the first clock reaches its limit, or at the leg's
    // end if neither does; each further one where the tighter limit is
    // reached again. Where a break falls along its leg changes no time, only
    // the clocks. At least one limit must be finite.
    [[nodiscard]] static BreakPlacement
    along(Duration drive, Duration work, Duration edge, BreakLimits limits)
    {
        auto const room = [](Duration stretch, Duration limit)
        { return stretch < limit ? limit - stretch : Duration(0); };

        return {std::min(
                    {edge, room(drive, limits.drive), room(work, limits.work)}),
                std::min(limits.drive, limits.work)};
    }
};

/**
 * Driving (or work) since the last break, folded over a segment the way
 * TripDistance is folded over trips. Breaks belong to legs, and fall along
 * them where BreakPlacement puts them. A real node doing q of the quantity
 * itself is {q, 0, q}.
 *
 * Where a leg's first break falls depends on both clocks' stretches, so one
 * clock alone does not fold: BreakClocks folds the two together. And it
 * depends on the stretches the leg continues, so merge() is exact only when
 * those are whole: when first starts where the route does, and second has no
 * reset of its own. A segment with resets extends the clocks by walking them
 * instead (search::Route's extendClocks()), which is why folds run from the
 * route's start.
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

    // A leg of `drive` carrying `breaks` >= 1, placed as `leg`, continuing a
    // stretch of `stretch`.
    [[nodiscard]] static BreakLeg acrossBreaks(Duration stretch,
                                               Duration drive,
                                               size_t breaks,
                                               BreakPlacement leg)
    {
        auto const left = drive - leg.before;
        auto const prepaid = static_cast<Duration>(breaks - 1) * leg.spacing;
        return {stretch + leg.before, left > prepaid ? left - prepaid : 0};
    }

    // `leg` places the breaks on the edge, if it carries any.
    [[nodiscard]] static DriveClock merge(DriveClock const &first,
                                          Duration edge,
                                          DriveClock const &second,
                                          Duration limit,
                                          BreakPlacement leg)
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

        auto const across = acrossBreaks(first.tail, edge, onLeg, leg);
        auto const after = across.after + second.head;

        out.head = first.resets ? first.head : across.closed;
        out.tail = second.resets ? second.tail : after;
        out.resets = first.resets + second.resets + 1;
        out.excess = first.excess + second.excess
                     + (first.resets ? clip(across.closed, limit) : 0)
                     + (second.resets ? clip(after, limit) : 0);
        out.need = first.need + second.need
                   + (first.resets ? needOf(across.closed, limit) : 0)
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

// Both clocks over a segment, folded together so each leg's breaks fall
// once for both (see BreakPlacement). An unbounded clock still folds; its
// limit only keeps it from placing a break or counting overrun.
struct BreakClocks
{
    DriveClock drive;
    DriveClock work;

    bool operator==(BreakClocks const &other) const = default;

    template <ClockQuantity Quantity> [[nodiscard]] DriveClock const &of() const
    {
        return Quantity == ClockQuantity::Drive ? drive : work;
    }

    [[nodiscard]] static BreakClocks merge(BreakClocks const &first,
                                           Duration edge,
                                           BreakClocks const &second,
                                           BreakLimits limits)
    {
        auto const leg = BreakPlacement::along(
            first.drive.tail, first.work.tail, edge, limits);

        return {
            DriveClock::merge(
                first.drive, edge, second.drive, limits.drive, leg),
            DriveClock::merge(first.work, edge, second.work, limits.work, leg)};
    }

    // A real node doing `drive` and `work` of each quantity itself.
    [[nodiscard]] static BreakClocks node(Duration drive, Duration work)
    {
        return {{.head = drive, .tail = drive}, {.head = work, .tail = work}};
    }

    // Breaks sitting on a leg: before the first real node, after the last.
    void addLeadRun(size_t count)
    {
        drive.leadRun += count;
        work.leadRun += count;
    }

    void addTrailRun(size_t count)
    {
        drive.trailRun += count;
        work.trailRun += count;
    }

    [[nodiscard]] Duration overrun(BreakLimits limits) const
    {
        return drive.overrun(limits.drive) + work.overrun(limits.work);
    }

    // Breaks lacking given both clocks: the larger count, as a break resets
    // both.
    [[nodiscard]] size_t missing(BreakLimits limits) const
    {
        return std::max(drive.missing(limits.drive), work.missing(limits.work));
    }
};
}  // namespace pyvrp

#endif  // PYVRP_DRIVECLOCK_H

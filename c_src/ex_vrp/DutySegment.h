#ifndef EX_VRP_DUTYSEGMENT_H
#define EX_VRP_DUTYSEGMENT_H

#include "DurationSegment.h"
#include "DutyLimits.h"
#include "Measure.h"

#include <cstddef>
#include <cstdint>
#include <limits>

namespace ex_vrp
{
/**
 * What a route's duty periods cost: their duty and driving past the limits,
 * summed, and the rests that would fix them, as virtual rests are priced.
 */
struct DutyCost
{
    Duration excess = 0;
    size_t missing = 0;

    DutyCost &operator+=(DutyCost const &other)
    {
        excess += other.excess;
        missing += other.missing;
        return *this;
    }
};

/**
 * The duty periods of a stretch of route: the time between two rests (see
 * Client::isRest), as EU 561/2006 art. 8(2) bounds it, and the driving in
 * each, as art. 6(1) does.
 *
 * A rest is to a duty period what a reload depot is to a trip: the period
 * after it starts afresh. Each period is measured as a duration segment of
 * its own, so waiting before its first visit lengthens the rest instead of
 * counting as duty, as the law allows (a rest lasts *at least* its
 * duration). Waiting between two visits of a period is duty. The route's own
 * duration segment keeps the timeline, rests included, so a period that
 * cannot start as early as it would like shows as time warp there.
 *
 * Travel on a leg that holds a rest is driven after it, and rests on one
 * leg, with nothing located between them, are one boundary: a period holds
 * at least one located node, except a route's first and last. So the travel
 * into a segment whose first located node comes after a rest goes into the
 * period that node is in.
 *
 * The periods before the first rest and after the last are kept open, so
 * that segments can still be merged onto them. So is the one between the
 * first two rests, the one a segment's leading rests open, which takes the
 * travel into the segment. Every other period is closed, as the cost it
 * adds. Merging is associative, so a route's prefixes, suffixes and any
 * proposal built from them agree.
 */
class DutySegment
{
    DurationSegment head_;      // Before the first rest; everything without one
    DurationSegment first_;     // Between the first two rests, if there are two
    DurationSegment tail_;      // After the last rest, if there is one
    DutyCost closed_;           // Every other period
    uint32_t rests_ = 0;        // Boundaries: rests on one leg count once
    bool headLocated_ = false;  // Whether head_ holds more than pauses
    bool tailLocated_ = false;  // Whether tail_ holds more than pauses

    [[nodiscard]] static inline DurationSegment
    prepend(Duration edge, DurationSegment const &segment);

    // Ends the open last period at a rest, and opens the given one after it.
    inline void
    open(DurationSegment const &period, bool located, DutyLimits const &limits);

    [[nodiscard]] static inline Duration pieces(Duration amount,
                                                Duration limit);

    [[nodiscard]] static inline DutyCost period(DurationSegment const &segment,
                                                Duration duty,
                                                Duration drive,
                                                DutyLimits const &limits);

public:
    /**
     * A node with a location: a depot or a client, with its duration segment.
     */
    [[nodiscard]] static inline DutySegment
    visit(DurationSegment const &segment);

    /**
     * A break, which is duty without a location: travel on its leg still
     * goes after it.
     */
    [[nodiscard]] static inline DutySegment
    pause(DurationSegment const &segment);

    /**
     * A rest, which ends one duty period and starts the next.
     */
    [[nodiscard]] static inline DutySegment rest();

    /**
     * The given segments one after the other, with ``edge`` of travel from
     * the last located node of ``first`` to the first of ``second``.
     */
    [[nodiscard]] static inline DutySegment merge(Duration edge,
                                                  DutySegment const &first,
                                                  DutySegment const &second,
                                                  DutyLimits const &limits);

    /**
     * What this segment's periods cost, as a whole route: the first period
     * takes the carries in, the last the duty after the end.
     */
    [[nodiscard]] inline DutyCost cost(DutyLimits const &limits) const;

    [[nodiscard]] inline size_t numRests() const;
};

DurationSegment DutySegment::prepend(Duration edge,
                                     DurationSegment const &segment)
{
    if (edge == 0)
        return segment;

    return DurationSegment::merge(edge, DurationSegment(), segment);
}

Duration DutySegment::pieces(Duration amount, Duration limit)
{
    if (limit == std::numeric_limits<Duration>::max() || amount <= limit)
        return 1;

    return (amount.get() + limit.get() - 1) / limit.get();
}

DutyCost DutySegment::period(DurationSegment const &segment,
                             Duration duty,
                             Duration drive,
                             DutyLimits const &limits)
{
    auto const net = segment.duration() - segment.timeWarp();
    auto const onDuty = std::max<Duration>(net, 0) + duty;
    auto const driving = segment.drive() + drive;

    auto const over = [](Duration amount, Duration limit)
    { return amount > limit ? amount - limit : Duration(0); };

    auto const needed
        = std::max(pieces(onDuty, limits.duty), pieces(driving, limits.drive));

    return {over(onDuty, limits.duty) + over(driving, limits.drive),
            static_cast<size_t>(needed.get() - 1)};
}

DutySegment DutySegment::visit(DurationSegment const &segment)
{
    DutySegment duty;
    duty.head_ = segment;
    duty.headLocated_ = true;
    return duty;
}

DutySegment DutySegment::pause(DurationSegment const &segment)
{
    DutySegment duty;
    duty.head_ = segment;
    return duty;
}

DutySegment DutySegment::rest()
{
    DutySegment duty;
    duty.rests_ = 1;
    return duty;
}

DutySegment DutySegment::merge(Duration edge,
                               DutySegment const &first,
                               DutySegment const &second,
                               DutyLimits const &limits)
{
    DutySegment merged = first;

    if (second.rests_ == 0)
    {
        if (first.rests_ == 0)
        {
            merged.head_
                = DurationSegment::merge(edge, first.head_, second.head_);
            merged.headLocated_ = first.headLocated_ || second.headLocated_;
        }
        else
        {
            merged.tail_
                = DurationSegment::merge(edge, first.tail_, second.head_);
            merged.tailLocated_ = first.tailLocated_ || second.headLocated_;
        }

        return merged;
    }

    // The leg into second is driven after its leading pauses, so after its
    // first rest when nothing located comes before that.
    auto const into = second.headLocated_ ? edge : Duration(0);
    auto const after = second.headLocated_ ? Duration(0) : edge;

    // The period second's first rest ends, and the one it opens.
    auto const fromHead = first.rests_ == 0;
    auto const &ending = fromHead ? first.head_ : first.tail_;
    auto const endingLocated
        = fromHead ? first.headLocated_ : first.tailLocated_;
    auto const closing = DurationSegment::merge(into, ending, second.head_);
    auto const closingLocated = endingLocated || second.headLocated_;

    auto const &next = second.rests_ >= 2 ? second.first_ : second.tail_;
    auto const nextLocated = second.rests_ >= 2 || second.tailLocated_;

    if (fromHead)
    {
        merged.head_ = closing;
        merged.headLocated_ = closingLocated;
        merged.open(prepend(after, next), nextLocated, limits);
    }
    else if (!closingLocated)
    {
        // Nothing located since first's last rest: second's first rest is
        // the same boundary, and the pauses between join the period after.
        merged.tail_ = DurationSegment::merge(after, closing, next);
        merged.tailLocated_ = nextLocated;
    }
    else
    {
        merged.tail_ = closing;
        merged.tailLocated_ = true;
        merged.open(prepend(after, next), nextLocated, limits);
    }

    if (second.rests_ >= 2)
    {
        merged.open(second.tail_, second.tailLocated_, limits);
        merged.rests_ += second.rests_ - 2;
        merged.closed_ += second.closed_;
    }

    return merged;
}

void DutySegment::open(DurationSegment const &next,
                       bool located,
                       DutyLimits const &limits)
{
    if (rests_ == 1)
        first_ = tail_;
    else if (rests_ >= 2)
        closed_ += period(tail_, 0, 0, limits);

    tail_ = next;
    tailLocated_ = located;
    ++rests_;
}

DutyCost DutySegment::cost(DutyLimits const &limits) const
{
    if (rests_ == 0)
        return period(head_,
                      limits.dutyCarryIn + limits.dutyAfterEnd,
                      limits.driveCarryIn,
                      limits);

    auto cost = period(head_, limits.dutyCarryIn, limits.driveCarryIn, limits);
    if (rests_ >= 2)
        cost += period(first_, 0, 0, limits);

    cost += closed_;
    cost += period(tail_, limits.dutyAfterEnd, 0, limits);
    return cost;
}

size_t DutySegment::numRests() const { return rests_; }
}  // namespace ex_vrp

#endif  // EX_VRP_DUTYSEGMENT_H

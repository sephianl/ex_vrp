#ifndef EX_VRP_LOADSEGMENT_H
#define EX_VRP_LOADSEGMENT_H

#include "Measure.h"
#include "ProblemData.h"

#include <iosfwd>

namespace ex_vrp
{
/**
 * LoadSegment(delivery: int, pickup: int, load: int, excess_load: int = 0)
 *
 * Creates a new load segment for delivery and pickup loads in a single
 * dimension. These load segments can be efficiently concatenated, and track
 * statistics about capacity violations resulting from visiting clients in the
 * concatenated order.
 *
 * Parameters
 * ----------
 * delivery
 *     Total delivery amount on this segment.
 * pickup
 *     Total pickup amount on this segment.
 * load
 *     Maximum load on this segment.
 * excess_load
 *     Cumulative excess load on this segment, possibly from earlier trips.
 */
class LoadSegment
{
    Load delivery_ = 0;    // of client demand on current trip
    Load pickup_ = 0;      // of client demand on current trip
    Load load_ = 0;        // on current trip
    Load excessLoad_ = 0;  // cumulative excess load over other trips in segment

public:
    [[nodiscard]] static inline LoadSegment merge(LoadSegment const &first,
                                                  LoadSegment const &second);

    /**
     * Finalises the load on this segment, and returns a new segment where any
     * excess load has been moved to the cumulative excess load field. This is
     * useful with reloading, because the finalised segment can be concatenated
     * with load segments of subsequent trips.
     */
    [[nodiscard]] inline LoadSegment finalise(Load capacity) const;

    /**
     * Returns the delivery amount, that is, the total amount of load delivered
     * to clients on this segment.
     */
    [[nodiscard]] Load delivery() const;

    /**
     * Returns the amount picked up from clients on this segment.
     */
    [[nodiscard]] Load pickup() const;

    /**
     * Returns the maximum load encountered on this segment.
     */
    [[nodiscard]] Load load() const;

    /**
     * Returns the load violation on this segment.
     *
     * Parameters
     * ----------
     * capacity
     *     Segment capacity, if any.
     */
    [[nodiscard]] inline Load excessLoad(Load capacity) const;

    LoadSegment() = default;  // default is all zero

    // Construct from load attributes of the given client and dimension.
    LoadSegment(ProblemData::Client const &client, size_t dimension);

    // Construct from the given client location's load in the given dimension,
    // its shipment's included. A shipment's amount is a pickup at its pickup
    // and a negative pickup at its delivery: Vidal's merge stays exact for
    // either sign, and carries the amount from one to the other. A pickup
    // whose delivery is not on the trip carries it to the trip's depot.
    inline LoadSegment(ProblemData const &data,
                       size_t client,
                       size_t dimension);

    // Construct from initial load attributes of the given vehicle type and
    // dimension.
    LoadSegment(ProblemData::VehicleType const &vehicleType, size_t dimension);

    // Construct from raw data.
    inline LoadSegment(Load delivery,
                       Load pickup,
                       Load load,
                       Load excessLoad = 0);

    // Move or copy construct from the other load segment.
    inline LoadSegment(LoadSegment const &) = default;
    inline LoadSegment(LoadSegment &&) = default;

    // Move or copy assign form the other load segment.
    inline LoadSegment &operator=(LoadSegment const &) = default;
    inline LoadSegment &operator=(LoadSegment &&) = default;
};

LoadSegment LoadSegment::merge(LoadSegment const &first,
                               LoadSegment const &second)
{
    // See Vidal et al. (2014) for details. This function implements equations
    // (9) -- (11) of https://doi.org/10.1016/j.ejor.2013.09.045.
    return {
        first.delivery_ + second.delivery_,
        first.pickup_ + second.pickup_,
        std::max(first.load_ + second.delivery_, second.load_ + first.pickup_),
        first.excessLoad_ + second.excessLoad_};
}

Load LoadSegment::excessLoad(Load capacity) const
{
    return excessLoad_ + std::max<Load>(load_ - capacity, 0);
}

LoadSegment LoadSegment::finalise(Load capacity) const
{
    return {0, 0, 0, excessLoad(capacity)};
}

LoadSegment::LoadSegment(ProblemData const &data,
                         size_t client,
                         size_t dimension)
{
    ProblemData::Client const &clientData = data.location(client);
    delivery_ = clientData.delivery[dimension];
    pickup_
        = clientData.pickup[dimension] + data.shipmentLoad(client, dimension);
    load_ = std::max<Load>(delivery_, pickup_);
}

LoadSegment::LoadSegment(Load delivery, Load pickup, Load load, Load excessLoad)
    : delivery_(delivery), pickup_(pickup), load_(load), excessLoad_(excessLoad)
{
}
}  // namespace ex_vrp

std::ostream &operator<<(std::ostream &out,  // helpful for debugging
                         ex_vrp::LoadSegment const &segment);

#endif  // EX_VRP_LOADSEGMENT_H

#ifndef PYVRP_SEARCH_SEGMENTS_H
#define PYVRP_SEARCH_SEGMENTS_H

#include "ProblemData.h"
#include "Route.h"

#include <cassert>
#include <limits>

namespace pyvrp::search
{
/**
 * Simple wrapper class that implements the required evaluation interface for
 * a single client that might not currently be in the solution.
 */
class ClientSegment
{
    ProblemData const &data;
    size_t client;

public:
    ClientSegment(ProblemData const &data, size_t client)
        : data(data), client(client)
    {
        assert(client >= data.numDepots());  // must be an actual client
        assert(!data.isBreak(client));       // breaks use BreakSegment
    }

    Route const *route() const { return nullptr; }

    bool hasLocation() const { return true; }
    size_t first() const { return client; }
    size_t last() const { return client; }
    size_t size() const { return 1; }

    bool startsAtReloadDepot() const { return false; }
    bool endsAtReloadDepot() const { return false; }

    Distance distance([[maybe_unused]] size_t profile) const { return 0; }

    TripDistance tripDistance([[maybe_unused]] size_t profile) const
    {
        return {};
    }

    Cost penalty(size_t profile, size_t vehicleType) const
    {
        return data.penalty(profile, client)
               + data.lockPenalty(vehicleType, client);
    }

    DurationSegment duration([[maybe_unused]] size_t profile) const
    {
        ProblemData::Client const &clientData = data.location(client);
        return {clientData};
    }

    LoadSegment load(size_t dimension) const
    {
        return {data.location(client), dimension};
    }
};

/**
 * Simple wrapper class that implements the required evaluation interface for
 * a single reload depot.
 */
class ReloadDepotSegment
{
    size_t depot_;

public:
    ReloadDepotSegment([[maybe_unused]] ProblemData const &data, size_t depot)
        : depot_(depot)
    {
        assert(depot < data.numDepots());  // must be an actual depot
    }

    Route const *route() const { return nullptr; }

    bool hasLocation() const { return true; }
    size_t first() const { return depot_; }
    size_t last() const { return depot_; }
    size_t size() const { return 1; }

    bool startsAtReloadDepot() const { return true; }
    bool endsAtReloadDepot() const { return true; }

    Distance distance([[maybe_unused]] size_t profile) const { return 0; }

    // A lone depot carries no distance of its own. It splits the trip around
    // it, which the fold reads off startsAtReloadDepot()/endsAtReloadDepot()
    // rather than from this value.
    TripDistance tripDistance([[maybe_unused]] size_t profile) const
    {
        return {};
    }

    Cost penalty([[maybe_unused]] size_t profile,
                 [[maybe_unused]] size_t vehicleType) const
    {
        // Depot penalties are required to be zero (ProblemData::validate), and
        // depots cannot be locked, so a reload depot contributes nothing to
        // the objective's penalty term.
        return 0;
    }

    DurationSegment duration([[maybe_unused]] size_t profile) const
    {
        // Empty segment - depot service time is handled by
        // Proposal::duration().
        return DurationSegment(
            0, 0, 0, std::numeric_limits<Duration>::max(), 0);
    }

    LoadSegment load([[maybe_unused]] size_t dimension) const { return {}; }
};

/**
 * Evaluation interface for a single break client, which might not currently
 * be in the solution. A break has no location, so the Proposal folds skip its
 * edges; it only adds its duration, in an unconstrained time window.
 */
class BreakSegment
{
    ProblemData const &data;
    size_t client;
    Duration breakDuration;

public:
    BreakSegment(ProblemData const &data, size_t client, Duration breakDuration)
        : data(data), client(client), breakDuration(breakDuration)
    {
        assert(data.isBreak(client));
    }

    Route const *route() const { return nullptr; }

    bool hasLocation() const { return false; }
    size_t first() const { return client; }
    size_t last() const { return client; }
    size_t size() const { return 1; }

    bool startsAtReloadDepot() const { return false; }
    bool endsAtReloadDepot() const { return false; }

    Distance distance([[maybe_unused]] size_t profile) const { return 0; }

    TripDistance tripDistance([[maybe_unused]] size_t profile) const
    {
        return {};
    }

    Cost penalty(size_t profile, [[maybe_unused]] size_t vehicleType) const
    {
        return data.penalty(profile, client);
    }

    DurationSegment duration([[maybe_unused]] size_t profile) const
    {
        return DurationSegment(
            breakDuration, 0, 0, std::numeric_limits<Duration>::max(), 0);
    }

    LoadSegment load([[maybe_unused]] size_t dimension) const { return {}; }
};

static_assert(Segment<ClientSegment>);
static_assert(Segment<ReloadDepotSegment>);
static_assert(Segment<BreakSegment>);
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_SEGMENTS_H

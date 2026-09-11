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
    }

    Route const *route() const { return nullptr; }

    size_t first() const { return client; }
    size_t last() const { return client; }
    size_t size() const { return 1; }

    bool startsAtReloadDepot() const { return false; }
    bool endsAtReloadDepot() const { return false; }

    Distance distance([[maybe_unused]] size_t profile) const { return 0; }

    Cost penalty(size_t profile) const { return data.penalty(profile, client); }

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

    size_t first() const { return depot_; }
    size_t last() const { return depot_; }
    size_t size() const { return 1; }

    bool startsAtReloadDepot() const { return true; }
    bool endsAtReloadDepot() const { return true; }

    Distance distance([[maybe_unused]] size_t profile) const { return 0; }

    Cost penalty([[maybe_unused]] size_t profile) const
    {
        // Depot penalties are required to be zero (ProblemData::validate), so
        // a reload depot contributes nothing to the objective's penalty term.
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
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_SEGMENTS_H

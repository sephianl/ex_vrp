#ifndef PYVRP_SEARCH_CLIENTSEGMENT_H
#define PYVRP_SEARCH_CLIENTSEGMENT_H

#include "DurationSegment.h"
#include "LoadSegment.h"
#include "Measure.h"
#include "ProblemData.h"
#include "Route.h"

#include <cassert>

namespace pyvrp::search
{
class ClientSegment
{
    ProblemData const &data;
    size_t client;

public:
    ClientSegment(ProblemData const &d, size_t c) : data(d), client(c)
    {
        assert(client >= data.numDepots());
    }

    Route const *route() const { return nullptr; }

    size_t first() const { return client; }
    size_t last() const { return client; }
    size_t size() const { return 1; }

    bool startsAtReloadDepot() const { return false; }
    bool endsAtReloadDepot() const { return false; }

    Distance distance([[maybe_unused]] size_t profile) const { return 0; }

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
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_CLIENTSEGMENT_H

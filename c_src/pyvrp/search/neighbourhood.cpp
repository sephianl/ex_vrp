#include "neighbourhood.h"

#include "ProblemData.h"

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <limits>
#include <set>
#include <tuple>
#include <vector>

namespace pyvrp::search
{
NeighbourhoodParams::NeighbourhoodParams(double weightWaitTime,
                                         size_t numNeighbours,
                                         bool symmetricProximity)
    : weightWaitTime(weightWaitTime),
      numNeighbours(numNeighbours),
      symmetricProximity(symmetricProximity)
{
    assert(numNeighbours > 0);
}

std::vector<std::vector<size_t>>
computeNeighbours(ProblemData const &data, NeighbourhoodParams const &params)
{
    double const weightWaitTime = params.weightWaitTime;
    double const weightTimeWarp = 1.0;
    size_t const numNeighbours = params.numNeighbours;
    bool const symmetricProximity = params.symmetricProximity;

    size_t const numLocs = data.numLocations();
    size_t const numDepots = data.numDepots();
    size_t const numClients = data.numClients();
    std::vector<std::vector<size_t>> neighbours(numLocs);

    std::set<std::tuple<Cost, Cost, size_t>> uniqueEdgeCosts;
    for (auto const &vt : data.vehicleTypes())
    {
        uniqueEdgeCosts.insert(
            {vt.unitDistanceCost, vt.unitDurationCost, vt.profile});
    }

    std::vector<std::vector<double>> edgeCosts(
        numLocs, std::vector<double>(numLocs, 0.0));
    bool first = true;
    for (auto const &[unitDist, unitDur, profile] : uniqueEdgeCosts)
    {
        auto const &distMat = data.distanceMatrix(profile);
        auto const &durMat = data.durationMatrix(profile);
        for (size_t i = 0; i < numLocs; ++i)
        {
            for (size_t j = 0; j < numLocs; ++j)
            {
                double cost = static_cast<double>(unitDist.get())
                                  * static_cast<double>(distMat(i, j).get())
                              + static_cast<double>(unitDur.get())
                                    * static_cast<double>(durMat(i, j).get());
                if (first)
                {
                    edgeCosts[i][j] = cost;
                }
                else
                {
                    edgeCosts[i][j] = std::min(edgeCosts[i][j], cost);
                }
            }
        }
        first = false;
    }

    std::vector<std::vector<double>> minDuration(numLocs,
                                                 std::vector<double>(numLocs));
    for (size_t i = 0; i < numLocs; ++i)
    {
        for (size_t j = 0; j < numLocs; ++j)
        {
            double minDur
                = static_cast<double>(data.durationMatrix(0)(i, j).get());
            for (size_t p = 1; p < data.numProfiles(); ++p)
            {
                minDur = std::min(
                    minDur,
                    static_cast<double>(data.durationMatrix(p)(i, j).get()));
            }
            minDuration[i][j] = minDur;
        }
    }

    std::vector<double> early(numLocs, 0.0);
    std::vector<double> late(numLocs, 0.0);
    std::vector<double> service(numLocs, 0.0);
    std::vector<double> prize(numLocs, 0.0);

    auto const &clients = data.clients();
    for (size_t c = 0; c < numClients; ++c)
    {
        size_t loc = numDepots + c;
        early[loc] = static_cast<double>(clients[c].twEarly.get());
        late[loc] = static_cast<double>(clients[c].twLate.get());
        service[loc] = static_cast<double>(clients[c].serviceDuration.get());
        prize[loc] = static_cast<double>(clients[c].prize.get());
    }

    for (size_t i = 0; i < numLocs; ++i)
    {
        for (size_t j = 0; j < numLocs; ++j)
        {
            edgeCosts[i][j] -= prize[j];

            double minWait
                = early[j] - minDuration[i][j] - service[i] - late[i];
            if (minWait > 0)
            {
                edgeCosts[i][j] += weightWaitTime * minWait;
            }

            double minTw = early[i] + service[i] + minDuration[i][j] - late[j];
            if (minTw > 0)
            {
                edgeCosts[i][j] += weightTimeWarp * minTw;
            }
        }
    }

    if (symmetricProximity)
    {
        for (size_t i = 0; i < numLocs; ++i)
        {
            for (size_t j = i + 1; j < numLocs; ++j)
            {
                double minVal = std::min(edgeCosts[i][j], edgeCosts[j][i]);
                edgeCosts[i][j] = minVal;
                edgeCosts[j][i] = minVal;
            }
        }
    }

    for (auto const &group : data.groups())
    {
        if (group.mutuallyExclusive)
        {
            auto const &groupClients = group.clients();
            for (size_t ci : groupClients)
            {
                for (size_t cj : groupClients)
                {
                    if (ci != cj)
                    {
                        edgeCosts[ci][cj] = std::numeric_limits<double>::max();
                    }
                }
            }
        }
    }

    for (size_t i = 0; i < numLocs; ++i)
    {
        edgeCosts[i][i] = std::numeric_limits<double>::infinity();
    }
    for (size_t d = 0; d < numDepots; ++d)
    {
        for (size_t j = 0; j < numLocs; ++j)
        {
            edgeCosts[d][j] = std::numeric_limits<double>::infinity();
            edgeCosts[j][d] = std::numeric_limits<double>::infinity();
        }
    }

    size_t k = std::min(numNeighbours, numClients - 1);
    for (size_t i = numDepots; i < numLocs; ++i)
    {
        std::vector<std::pair<double, size_t>> proximities;
        for (size_t j = numDepots; j < numLocs; ++j)
        {
            if (i != j)
            {
                proximities.emplace_back(edgeCosts[i][j], j);
            }
        }

        if (!proximities.empty())
        {
            size_t k_actual = std::min(k, proximities.size());
            std::partial_sort(proximities.begin(),
                              proximities.begin() + k_actual,
                              proximities.end());

            for (size_t n = 0; n < k_actual; ++n)
            {
                neighbours[i].push_back(proximities[n].second);
            }
        }
    }

    return neighbours;
}
}  // namespace pyvrp::search

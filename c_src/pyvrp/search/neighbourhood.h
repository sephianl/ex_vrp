#ifndef PYVRP_SEARCH_NEIGHBOURHOOD_H
#define PYVRP_SEARCH_NEIGHBOURHOOD_H

#include "ProblemData.h"

#include <cstddef>
#include <vector>

namespace pyvrp::search
{
struct NeighbourhoodParams
{
    double weightWaitTime = 0.2;
    size_t numNeighbours = 60;
    bool symmetricProximity = true;

    NeighbourhoodParams(double weightWaitTime = 0.2,
                        size_t numNeighbours = 60,
                        bool symmetricProximity = true);
};

std::vector<std::vector<size_t>>
computeNeighbours(pyvrp::ProblemData const &data,
                  NeighbourhoodParams const &params = {});
}  // namespace pyvrp::search

#endif  // PYVRP_SEARCH_NEIGHBOURHOOD_H

#ifndef PYVRP_PIECEWISELINEARFUNCTION_H
#define PYVRP_PIECEWISELINEARFUNCTION_H

#include <cassert>
#include <limits>
#include <stdexcept>
#include <utility>
#include <vector>

namespace pyvrp
{
template <typename Dom, typename Co> class PiecewiseLinearFunction
{
public:
    using Segment = std::pair<Dom, Dom>;

private:
    std::vector<Dom> breakpoints_;
    std::vector<Segment> segments_;

public:
    PiecewiseLinearFunction(std::vector<Dom> breakpoints,
                            std::vector<Segment> segments);

    [[nodiscard]] inline Co operator()(Dom x) const;

    [[nodiscard]] std::vector<Dom> const &breakpoints() const;

    [[nodiscard]] std::vector<Segment> const &segments() const;

    bool operator==(PiecewiseLinearFunction const &other) const = default;
};

template <typename Dom, typename Co>
PiecewiseLinearFunction<Dom, Co>::PiecewiseLinearFunction(
    std::vector<Dom> breakpoints, std::vector<Segment> segments)
    : breakpoints_(std::move(breakpoints)), segments_(std::move(segments))
{
    if (segments_.empty())
        throw std::invalid_argument("Need at least one segment.");

    if (breakpoints_.size() != segments_.size())
        throw std::invalid_argument(
            "Number of breakpoints and segments must match.");

    for (size_t idx = 0; idx != breakpoints_.size() - 1; ++idx)
        if (breakpoints_[idx] >= breakpoints_[idx + 1])
            throw std::invalid_argument(
                "Breakpoints must be strictly increasing.");
}

template <typename Dom, typename Co>
Co PiecewiseLinearFunction<Dom, Co>::operator()(Dom x) const
{
    for (size_t idx = 0; idx != breakpoints_.size(); ++idx)
        if (x < breakpoints_[idx])
        {
            auto const [intercept, slope] = segments_[idx];
            return static_cast<Co>(intercept + slope * x);
        }

    auto const [intercept, slope] = segments_.back();
    return static_cast<Co>(intercept + slope * x);
}

template <typename Dom, typename Co>
std::vector<Dom> const &PiecewiseLinearFunction<Dom, Co>::breakpoints() const
{
    return breakpoints_;
}

template <typename Dom, typename Co>
std::vector<typename PiecewiseLinearFunction<Dom, Co>::Segment> const &
PiecewiseLinearFunction<Dom, Co>::segments() const
{
    return segments_;
}
}  // namespace pyvrp

#endif  // PYVRP_PIECEWISELINEARFUNCTION_H

#ifndef PYVRP_ACTIVITY_H
#define PYVRP_ACTIVITY_H

#include <cstddef>
#include <ostream>
#include <string>

namespace pyvrp
{
struct Activity
{
    enum class ActivityType
    {
        DEPOT = 0,
        CLIENT = 1,
    };

    ActivityType const type;
    size_t const idx;

    Activity(ActivityType type, size_t idx);

    Activity(std::string const &description);

    bool operator==(Activity const &other) const = default;

    inline bool isClient() const;
    inline bool isDepot() const;
};
}  // namespace pyvrp

bool pyvrp::Activity::isClient() const { return type == ActivityType::CLIENT; }
bool pyvrp::Activity::isDepot() const { return type == ActivityType::DEPOT; }

std::ostream &operator<<(std::ostream &out, pyvrp::Activity const &activity);

#endif  // PYVRP_ACTIVITY_H

#ifndef EX_VRP_DUTYLIMITS_H
#define EX_VRP_DUTYLIMITS_H

#include "Measure.h"

namespace ex_vrp
{
/**
 * What bounds one duty period, the time between two rests (see
 * DutySegment), and what the route's first and last periods carry in from
 * outside it. A limit of max() bounds nothing.
 */
struct DutyLimits
{
    Duration duty;          // Elapsed time, waiting included
    Duration drive;         // Travel only
    Duration dutyCarryIn;   // Duty before the route, in its first period
    Duration driveCarryIn;  // Driving before the route, in its first period
    Duration dutyAfterEnd;  // Duty after the route, in its last period
};
}  // namespace ex_vrp

#endif  // EX_VRP_DUTYLIMITS_H

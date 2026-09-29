#include "Route.h"
#include "DriveClock.h"
#include "DurationSegment.h"
#include "LoadSegment.h"

#include <algorithm>
#include <cassert>
#include <fstream>
#include <numeric>

using pyvrp::ClockQuantity;
using pyvrp::Coordinate;
using pyvrp::Cost;
using pyvrp::Distance;
using pyvrp::Duration;
using pyvrp::Load;
using pyvrp::Route;
using pyvrp::Trip;

using Client = size_t;

Route::Iterator::Iterator(Route const &route, size_t idx)
    : route_(&route), trip_(route.numTrips()), idx_(0)
{
    assert(idx <= route.size());

    auto const &trips = route.trips();
    for (size_t trip = 0; trip != trips.size(); ++trip)
    {
        if (idx < trips[trip].size())
        {
            trip_ = trip;
            idx_ = idx;
            break;
        }

        idx -= trips[trip].size();
    }
}

bool Route::Iterator::operator==(Iterator const &other) const
{
    return route_ == other.route_ && trip_ == other.trip_ && idx_ == other.idx_;
}

Client Route::Iterator::operator*() const
{
    auto const &trips = route_->trips();
    assert(trip_ < trips.size());
    assert(idx_ < trips[trip_].size());

    return trips[trip_][idx_];
}

Route::Iterator Route::Iterator::operator++(int)
{
    auto tmp = *this;
    ++*this;
    return tmp;
}

Route::Iterator &Route::Iterator::operator++()
{
    auto const &trips = route_->trips();
    if (idx_ + 1 < trips[trip_].size())
    {
        ++idx_;
        return *this;
    }

    // Then we move to the next trip. This trip could be empty - in that case
    // we continue to the next until we either exhaust all trips, or we find a
    // non-empty trip.
    ++trip_;
    while (trip_ < trips.size() && trips[trip_].empty())
        ++trip_;

    idx_ = 0;
    return *this;
}

Route::ScheduledVisit::ScheduledVisit(size_t location,
                                      size_t trip,
                                      Duration startService,
                                      Duration endService,
                                      Duration waitDuration,
                                      Duration timeWarp)
    : location(location),
      trip(trip),
      startService(startService),
      endService(endService),
      waitDuration(waitDuration),
      timeWarp(timeWarp)
{
    assert(startService <= endService);
}

Duration Route::ScheduledVisit::serviceDuration() const
{
    return endService - startService;
}

void Route::validate(ProblemData const &data) const
{
    auto const &vehData = data.vehicleType(vehicleType_);

    if (trips_.size() > vehData.maxTrips())
        throw std::invalid_argument("Vehicle cannot perform this many trips.");

    if (trips_[0].startDepot() != startDepot_)
    {
        auto const *msg = "Route must start at vehicle's start_depot.";
        throw std::invalid_argument(msg);
    }

    if (trips_.back().endDepot() != endDepot_)
        throw std::invalid_argument("Route must end at vehicle's end_depot.");

    for (auto const &trip : trips_)
        if (trip.vehicleType() != vehicleType_)
        {
            auto const *msg = "Each trip must use the route's vehicle type.";
            throw std::invalid_argument(msg);
        }

    for (size_t idx = 0; idx + 1 != trips_.size(); ++idx)
        if (trips_[idx].endDepot() != trips_[idx + 1].startDepot())
        {
            auto *msg = "Consecutive trips must start at previous' end_depot.";
            throw std::invalid_argument(msg);
        }
}

void Route::makeSchedule(ProblemData const &data)
{
    schedule_.clear();
    schedule_.reserve(size() + numTrips() + 1);  // clients and depots

    auto const &vehData = data.vehicleType(vehicleType_);
    auto const &durations = data.durationMatrix(vehData.profile);

    auto now = startTime_;
    auto const handle
        = [&](auto const &where, size_t location, size_t trip, Duration service)
    {
        // Wait for forbidden window at ANY location (not just clients).
        // During a forbidden window the vehicle must be idle at the depot,
        // so no service, travel, or reloading may start.
        Duration forbiddenWait = 0;
        auto const advanced
            = advancePastForbidden(now, vehData.forbiddenWindows);
        if (advanced != now)
        {
            forbiddenWait = advanced > now ? advanced - now : Duration(0);
            now = advanced;
        }

        auto const wait
            = where.twEarly > now ? where.twEarly - now : Duration(0);
        auto const tw = now > where.twLate ? now - where.twLate : Duration(0);

        now += wait;
        now -= tw;

        // Check if service would extend into a forbidden window.
        // If so, delay service start to after the forbidden window.
        for (auto const &[fStart, fEnd] : vehData.forbiddenWindows)
        {
            if (now < fStart && now + service > fStart)
            {
                forbiddenWait += fEnd > now ? fEnd - now : Duration(0);
                now = fEnd;
                break;
            }
        }

        schedule_.emplace_back(
            location, trip, now, now + service, wait + forbiddenWait, tw);

        now += service;
    };

    for (size_t tripIdx = 0; tripIdx != trips_.size(); ++tripIdx)
    {
        auto const &trip = trips_[tripIdx];
        ProblemData::Depot const &start = data.location(trip.startDepot());

        auto const earliestStart = std::max(
            start.twEarly, std::min(trip.releaseTime(), start.twLate));
        auto const latestStart = tripIdx == 0  // first trip also accounts for
                                               // the latest start constraint
                                     ? std::min(start.twLate, vehData.startLate)
                                     : start.twLate;

        auto const wait
            = earliestStart > now ? earliestStart - now : Duration(0);
        auto const tw = now > latestStart ? now - latestStart : Duration(0);

        now += wait;
        now -= tw;

        // Wait for forbidden window before reload service starts.
        Duration forbiddenWait = 0;
        auto const advanced
            = advancePastForbidden(now, vehData.forbiddenWindows);
        if (advanced != now)
        {
            forbiddenWait = advanced > now ? advanced - now : Duration(0);
            now = advanced;
        }

        // Apply depot service time for reload depots (not for the first trip)
        auto const depotService = tripIdx > 0 ? start.serviceDuration : 0;
        auto const depotStart = now;
        now += depotService;

        // After reload service, the vehicle may now be in a forbidden
        // window.  Wait at the depot until it ends.
        if (tripIdx > 0 && !vehData.forbiddenWindows.empty())
        {
            auto const afterReload
                = advancePastForbidden(now, vehData.forbiddenWindows);
            if (afterReload != now)
                now = afterReload;
        }

        // Lookahead: if departing after reload would put the vehicle at
        // the first client's location during a forbidden window, wait at
        // the depot instead (the vehicle must be idle at the depot during
        // forbidden windows, not idle at a client location).
        if (tripIdx > 0 && !vehData.forbiddenWindows.empty() && !trip.empty())
        {
            // A leading break takes the depot's location, as in the loop
            // below and in search::Route's forbidden-window walk.
            auto const firstClient = *trip.begin();
            auto const firstLoc
                = data.isBreak(firstClient) ? trip.startDepot() : firstClient;
            auto const travel = durations(trip.startDepot(), firstLoc);
            auto const arrive = now + travel;
            ProblemData::Client const &cd = data.location(firstClient);
            auto const svcStart = std::max(arrive, cd.twEarly);

            auto const svcEnd
                = svcStart
                  + (data.isBreak(firstClient) ? vehData.breakDuration
                                               : cd.serviceDuration);
            for (auto const &[fStart, fEnd] : vehData.forbiddenWindows)
            {
                // Would the vehicle be present at the client during
                // [fStart, fEnd)? Check if arrival/service overlaps
                // the forbidden window.
                if (arrive < fEnd && svcEnd > fStart && fEnd > now)
                {
                    now = fEnd;
                    break;
                }
            }
        }

        schedule_.emplace_back(trip.startDepot(),
                               tripIdx,
                               depotStart,
                               now,
                               wait + forbiddenWait,
                               tw);

        // A break takes the location of the nearest non-break node before it.
        size_t prevLoc = trip.startDepot();
        for (auto const client : trip)
        {
            auto const loc = data.isBreak(client) ? prevLoc : client;
            assert(!data.isBreak(prevLoc) && !data.isBreak(loc));
            now += durations(prevLoc, loc);

            ProblemData::Client const &clientData = data.location(client);
            auto const service = data.isBreak(client)
                                     ? vehData.breakDuration
                                     : clientData.serviceDuration;
            handle(clientData, client, tripIdx, service);

            prevLoc = loc;
        }

        now += durations(prevLoc, trip.endDepot());
    }

    ProblemData::Depot const &end = data.location(endDepot_);
    handle(end, endDepot_, numTrips(), 0);
}

Route::Route(ProblemData const &data, Visits visits, size_t vehicleType)
    : Route(data, {{data, std::move(visits), vehicleType}}, vehicleType)
{
}

Route::Route(ProblemData const &data, Trips trips, size_t vehType)
    : trips_(std::move(trips)),
      delivery_(data.numLoadDimensions(), 0),
      pickup_(data.numLoadDimensions(), 0),
      excessLoad_(data.numLoadDimensions(), 0),
      reloadCost_(0),
      vehicleType_(vehType)
{
    if (trips_.empty())  // then we insert a dummy trip for ease.
        trips_.emplace_back(data, Visits{}, vehType);

    auto const &vehData = data.vehicleType(vehType);
    startDepot_ = vehData.startDepot;
    endDepot_ = vehData.endDepot;

    validate(data);

    auto const &penalties = data.penalties(vehData.profile);
    for (auto const &trip : trips_)  // general statistics
    {
        distance_ += trip.distance();
        excessDistance_ += std::max<Distance>(
            trip.distance() - vehData.maxDistancePerTrip, 0);
        service_ += trip.serviceDuration();
        travel_ += trip.travelDuration();
        prizes_ += trip.prizes();

        for (auto const client : trip)
        {
            if (data.isBreak(client))
                breaks_ += vehData.breakDuration;

            penaltyCost_ += penalties[client];

            auto const lock = data.lockPenalty(vehType, client);
            lockCost_ += lock;
            penaltyCost_ += lock;

            // Counted, not asserted away. This constructor evaluates whatever
            // routes it is handed, and callers do hand it forbidden ones: a
            // warm start via :initial_routes, or a solution built straight
            // from route lists. Those arrive from outside the search, where
            // the pruning predicate never ran, so a count here is data rather
            // than a broken invariant. Search output is a different matter,
            // and the seed sweep in test/is_allowed_test.exs holds it to zero.
            if (!data.isAllowed(vehData.profile, client))
                numForbiddenVisits_++;
        }
    }

    distanceCost_ = vehData.unitDistanceCost * static_cast<Cost>(distance_);
    excessDistance_ += std::max<Distance>(distance_ - vehData.maxDistance, 0);

    for (size_t idx = 0; idx != trips_.size(); ++idx)  // load statistics
    {
        auto const &trip = trips_[idx];
        auto const &tripDeliv = trip.delivery();
        auto const &tripPick = trip.pickup();
        auto const &tripLoad = trip.load();

        for (size_t dim = 0; dim != data.numLoadDimensions(); ++dim)
        {
            LoadSegment ls = {tripDeliv[dim], tripPick[dim], tripLoad[dim], 0};

            if (idx == 0 && vehData.initialLoad[dim] > 0)
                // This is initial load that the first trip does not know about
                // that we need to account for first.
                ls = LoadSegment::merge({vehData, dim}, ls);

            delivery_[dim] += ls.delivery();
            pickup_[dim] += ls.pickup();
            excessLoad_[dim] += ls.excessLoad(vehData.capacity[dim]);
        }
    }

    // Duration statistics. We iterate in reverse, that is, from the last to
    // the first visit.
    auto const &durations = data.durationMatrix(vehData.profile);
    DurationSegment ds = {vehData, vehData.twLate};
    for (auto trip = trips_.rbegin(); trip != trips_.rend(); ++trip)
    {
        if (trip != trips_.rbegin())  // need to finalise before next trip,
            ds = ds.finaliseFront();  // unless this is the first one

        ProblemData::Depot const &end = data.location(trip->endDepot());
        ds = DurationSegment::merge(0, {end}, ds);

        // Walking backwards, a break takes the location of the nearest
        // non-break node after it, as in search::Route's durAfter: its
        // outgoing edge is zero and the node before it drives on. Timing is
        // the same as driving after the break, since a break has no window.
        size_t nextLoc = trip->endDepot();
        for (auto it = trip->rbegin(); it != trip->rend(); ++it)
        {
            auto const client = *it;
            auto const loc = data.isBreak(client) ? nextLoc : client;
            assert(!data.isBreak(loc) && !data.isBreak(nextLoc));
            auto const edgeDuration = durations(loc, nextLoc);
            ProblemData::Client const &clientData = data.location(client);
            DurationSegment const visitDS
                = data.isBreak(client)
                      ? DurationSegment(vehData.breakDuration,
                                        0,
                                        0,
                                        std::numeric_limits<Duration>::max(),
                                        0)
                      : DurationSegment(clientData);

            ds = DurationSegment::merge(edgeDuration, visitDS, ds);
            nextLoc = loc;
        }

        auto const edgeDuration = durations(trip->startDepot(), nextLoc);
        ProblemData::Depot const &start = data.location(trip->startDepot());
        // Service time and reload cost are only applied at reload depots (not
        // the first trip). In reverse iteration, trip + 1 == rend means this is
        // the first trip.
        bool const isReloadDepot = (trip + 1) != trips_.rend();
        Duration const serviceTime = isReloadDepot ? start.serviceDuration : 0;
        if (isReloadDepot)
            reloadCost_ += start.reloadCost;
        DurationSegment const depotDS(
            serviceTime, 0, 0, std::numeric_limits<Duration>::max(), 0);

        ds = DurationSegment::merge(edgeDuration, depotDS, ds);
    }

    ds = DurationSegment::merge(0, {vehData, vehData.startLate}, ds);

    duration_ = ds.duration();
    startTime_ = ds.startEarly();
    slack_ = ds.slack();
    timeWarp_ = ds.timeWarp(vehData.maxDuration);

    // overtime_ reads timeWarp_ through endTime(), which subtracts
    // timelineTimeWarp() rather than timeWarp_ directly; driveExcess_ is
    // still its default (0) here, so this is equivalent either way, and
    // computing it before driveExcess_ is folded into timeWarp_ below keeps
    // that invariant obviously true rather than incidental.
    overtime_ = vehData.overtime(endTime(), duration_);
    durationCost_ = vehData.unitDurationCost * static_cast<Cost>(duration_)
                    + vehData.unitOvertimeCost * static_cast<Cost>(overtime_);

    driveExcess_ = ds.driveExcess(vehData.maxDrive);
    clockExcess_ = foldClockExcess<ClockQuantity::Drive>(data);
    workClockExcess_ = foldClockExcess<ClockQuantity::Work>(data);
    timeWarp_ += driveExcess_ + clockExcess_ + workClockExcess_;

    makeSchedule(data);

    // When forbidden windows exist, the schedule includes waits that the
    // DurationSegment calculation does not know about. Recompute the route
    // metrics from the actual schedule so they reflect reality.
    if (!vehData.forbiddenWindows.empty())
    {
        duration_
            = schedule_.back().endService - schedule_.front().startService;
        overtime_ = vehData.overtime(schedule_.back().endService, duration_);
        durationCost_
            = vehData.unitDurationCost * static_cast<Cost>(duration_)
              + vehData.unitOvertimeCost * static_cast<Cost>(overtime_);

        timeWarp_ = 0;
        for (auto const &visit : schedule_)
            timeWarp_ += visit.timeWarp;
        if (duration_ > vehData.maxDuration)
            timeWarp_ += duration_ - vehData.maxDuration;
        timeWarp_ += driveExcess_ + clockExcess_ + workClockExcess_;
    }
}

template <ClockQuantity Quantity>
Duration Route::foldClockExcess(ProblemData const &data) const
{
    auto const &vehData = data.vehicleType(vehicleType_);
    auto const limit = vehData.breakLimit(Quantity);
    if (limit == std::numeric_limits<Duration>::max() || empty())
        return 0;

    auto constexpr work = Quantity == ClockQuantity::Work;

    // The clock runs across reload depots, which are work, not rest. Breaks
    // count onto the leg they sit on, as in search::Route's fold. The carries
    // are the start and end depots' own quantity, as in search::Route.
    auto const &durations = data.durationMatrix(vehData.profile);
    auto const carryIn = work ? vehData.workCarryIn : vehData.driveCarryIn;
    DriveClock clock = {.head = carryIn, .tail = carryIn};
    size_t last = startDepot_;

    auto const visit = [&](size_t location, Duration own)
    {
        if (data.isBreak(location))
            clock.trailRun++;
        else
        {
            DriveClock const node = {.head = own, .tail = own};
            clock = DriveClock::merge(
                clock, durations(last, location), node, limit);
            last = location;
        }
    };

    for (size_t tripIdx = 0; tripIdx != trips_.size(); ++tripIdx)
    {
        if (tripIdx > 0)  // a reload depot, whose service is work
        {
            auto const depot = trips_[tripIdx].startDepot();
            ProblemData::Depot const &depotData = data.location(depot);
            visit(depot, work ? depotData.serviceDuration : 0);
        }

        for (auto const client : trips_[tripIdx])
        {
            ProblemData::Client const &clientData = data.location(client);
            visit(client, work ? clientData.serviceDuration : 0);
        }
    }

    visit(endDepot_, work ? vehData.workAfterEnd : 0);
    return clock.overrun(limit);
}

bool Route::empty() const { return size() == 0; }

size_t Route::size() const
{
    return std::accumulate(trips_.begin(),
                           trips_.end(),
                           0,
                           [](size_t count, auto const &trip)
                           { return count + trip.size(); });
}

size_t Route::numTrips() const { return trips_.size(); }

Client Route::operator[](size_t idx) const
{
    for (auto const &trip : trips_)
        if (idx < trip.size())
            return trip[idx];
        else
            idx -= trip.size();

    throw std::out_of_range("Index out of range.");
}

Route::Iterator Route::begin() const { return Iterator(*this, 0); }

Route::Iterator Route::end() const { return Iterator(*this, size()); }

Route::Trips const &Route::trips() const { return trips_; }

Trip const &Route::trip(size_t idx) const
{
    assert(idx < trips_.size());
    return trips_[idx];
}

Route::Visits Route::visits() const { return {begin(), end()}; }

std::vector<Route::ScheduledVisit> const &Route::schedule() const
{
    return schedule_;
}

Distance Route::distance() const { return distance_; }

Cost Route::distanceCost() const { return distanceCost_; }

Distance Route::excessDistance() const { return excessDistance_; }

std::vector<Load> const &Route::delivery() const { return delivery_; }

std::vector<Load> const &Route::pickup() const { return pickup_; }

std::vector<Load> const &Route::excessLoad() const { return excessLoad_; }

Duration Route::duration() const { return duration_; }

Duration Route::overtime() const { return overtime_; }

Cost Route::durationCost() const { return durationCost_; }

Duration Route::serviceDuration() const { return service_; }

Duration Route::timeWarp() const { return timeWarp_; }

Duration Route::driveExcess() const { return driveExcess_; }

Duration Route::clockExcess() const { return clockExcess_; }

Duration Route::workClockExcess() const { return workClockExcess_; }

Duration Route::timelineTimeWarp() const
{
    return timeWarp_ - driveExcess_ - clockExcess_ - workClockExcess_;
}

Duration Route::waitDuration() const
{
    return duration_ - travel_ - service_ - breaks_;
}

Duration Route::travelDuration() const { return travel_; }

Duration Route::startTime() const { return startTime_; }

Duration Route::endTime() const
{
    return startTime_ + duration_ - timelineTimeWarp();
}

Duration Route::slack() const { return slack_; }

Duration Route::releaseTime() const { return trips_[0].releaseTime(); }

Cost Route::prizes() const { return prizes_; }

Cost Route::reloadCost() const { return reloadCost_; }

Cost Route::penaltyCost() const { return penaltyCost_; }

Cost Route::lockCost() const { return lockCost_; }

size_t Route::numForbiddenVisits() const { return numForbiddenVisits_; }

size_t Route::vehicleType() const { return vehicleType_; }

size_t Route::startDepot() const { return startDepot_; }

size_t Route::endDepot() const { return endDepot_; }

bool Route::isFeasible() const
{
    return !hasExcessLoad() && !hasTimeWarp() && !hasExcessDistance();
}

bool Route::hasExcessLoad() const
{
    return std::any_of(excessLoad_.begin(),
                       excessLoad_.end(),
                       [](auto const excess) { return excess > 0; });
}

bool Route::hasExcessDistance() const { return excessDistance_ > 0; }

bool Route::hasTimeWarp() const { return timeWarp_ > 0; }

bool Route::operator==(Route const &other) const
{
    // First compare simple attributes, since that's a quick and cheap check.
    // Only when these are the same we test if the visits are all equal.
    // clang-format off
    return distance_ == other.distance_
        && duration_ == other.duration_
        && timeWarp_ == other.timeWarp_
        && vehicleType_ == other.vehicleType_
        && trips_ == other.trips_;
    // clang-format on
}

std::ostream &operator<<(std::ostream &out, Route const &route)
{
    auto const &trips = route.trips();
    for (size_t idx = 0; idx != trips.size(); ++idx)
    {
        if (idx != 0)
            out << " | ";
        out << trips[idx];
    }

    return out;
}

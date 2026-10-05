#ifndef PYVRP_SEARCH_ROUTE_H
#define PYVRP_SEARCH_ROUTE_H

#include "../Route.h"  // pyvrp::Route
#include "DriveClock.h"
#include "DurationSegment.h"
#include "LoadSegment.h"
#include "ProblemData.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <concepts>
#include <iosfwd>
#include <utility>

namespace pyvrp::search
{
/**
 * A segment's travel distance, split at the trip boundaries inside it.
 *
 * ``head`` runs from the segment's start to its first internal reload depot,
 * ``tail`` from its last internal reload depot to the segment's end, and
 * ``excess`` is the already-clipped excess of every trip lying wholly inside
 * the segment. A segment with no internal boundary has ``split == false``,
 * carries its entire distance in ``head``, and leaves ``tail`` and ``excess``
 * at zero.
 *
 * Head and tail stay unclipped on purpose. Both are partial trips that keep
 * growing as segments are concatenated, so only the fold in
 * ``Proposal::tripExcessDistance`` knows when either one finally closes.
 * ``distance()`` cannot answer this: it is a plain prefix-sum subtraction that
 * discards trip identity, which is exactly what makes it cheap.
 */
struct TripDistance
{
    Distance head = 0;
    Distance excess = 0;
    Distance tail = 0;
    bool split = false;
};

// This defines the minimal interface required for a segment of visits.
// Break clients have no location. A segment holding only breaks reports
// hasLocation() == false, and its first() and last() must not be used in edge
// lookups; any other segment's first() and last() are its first and last
// non-break locations. driveClock() and workClock() are only called with a
// finite limit; workClock() is driveClock() plus each real node's service.
template <typename T>
concept Segment = requires(T arg,
                           size_t profile,
                           size_t vehicleType,
                           size_t dimension,
                           Duration limit) {
    { arg.route() };
    { arg.hasLocation() } -> std::same_as<bool>;
    { arg.first() } -> std::same_as<size_t>;
    { arg.last() } -> std::same_as<size_t>;
    { arg.size() } -> std::same_as<size_t>;
    { arg.numBreaks() } -> std::same_as<size_t>;
    { arg.startsAtReloadDepot() } -> std::same_as<bool>;
    { arg.endsAtReloadDepot() } -> std::same_as<bool>;
    { arg.distance(profile) } -> std::convertible_to<Distance>;
    { arg.tripDistance(profile) } -> std::convertible_to<TripDistance>;
    { arg.penalty(profile, vehicleType) } -> std::convertible_to<Cost>;
    {
        arg.duration(profile, vehicleType)
    } -> std::convertible_to<DurationSegment>;
    { arg.driveClock(profile, limit) } -> std::convertible_to<DriveClock>;
    { arg.workClock(profile, limit) } -> std::convertible_to<DriveClock>;
    { arg.load(dimension) } -> std::convertible_to<LoadSegment>;
};

// A segment's clock over the given quantity.
template <ClockQuantity Quantity, Segment T>
DriveClock clockOf(T const &segment, size_t profile, Duration limit)
{
    if constexpr (Quantity == ClockQuantity::Drive)
        return segment.driveClock(profile, limit);
    else
        return segment.workClock(profile, limit);
}

namespace detail
{
template <class Tuple, std::size_t... Indices>
auto constexpr reverse_impl(Tuple &&tuple, std::index_sequence<Indices...>)
{
    return std::make_tuple(std::get<sizeof...(Indices) - 1 - Indices>(
        std::forward<Tuple>(tuple))...);
}

template <class Tuple> auto constexpr reverse(Tuple &&tuple)
{
    auto constexpr size = std::tuple_size_v<std::remove_reference_t<Tuple>>;
    auto constexpr indices = std::make_index_sequence<size>{};
    return reverse_impl(tuple, indices);
}
}  // namespace detail

/**
 * This ``Route`` class supports fast delta cost computations and in-place
 * modification. It can be used to implement move evaluations.
 *
 * A ``Route`` object tracks a full route, including the depots. The clients
 * and depots on the route can be accessed using ``Route::operator[]`` on a
 * ``route`` object.
 *
 * .. note::
 *
 *    Modifications to the ``Route`` object do not immediately propagate to its
 *    statistics like time window, load and distance data. To make that happen,
 *    ``Route::update()`` must be called!
 */
class Route
{
public:
    /**
     * A simple class that tracks a proposed route structure. This new structure
     * can be efficiently evaluated by calling appropriate member functions,
     * detailing the newly proposed route's statistics.
     *
     * .. note::
     *
     *    The member functions may shortcut if they detect that a particular
     *    statistic has no impact on the newly proposed route's cost.
     */
    template <Segment... Segments> class Proposal
    {
        std::tuple<Segments...> segments_;

        // Every cost method asks, so the fold over segments_ runs once.
        bool empty_;

        // Whether any segment holds a break. Without one every segment is
        // located and its ends are its own nodes, so distance() and duration()
        // fold without the break lookups.
        bool withBreaks_;

        /**
         * Returns the number of depots and clients in the proposed route.
         */
        size_t size() const;

        // The folds behind distance() and duration(). Without breaks they
        // inline into their caller; the WithBreaks ones stay out of line, so
        // their lookups never count against the inlining of models without
        // breaks.
        template <bool WithBreaks>
        [[gnu::always_inline]] inline std::pair<Cost, Distance>
        foldDistance() const;

        template <bool WithBreaks>
        [[gnu::always_inline]] inline std::pair<Cost, Duration>
        foldDuration() const;

        [[gnu::noinline]] std::pair<Cost, Distance> distanceWithBreaks() const;
        [[gnu::noinline]] std::pair<Cost, Duration> durationWithBreaks() const;

        // Breaks across the segments, out of line for the same reason.
        [[gnu::noinline]] size_t countBreaks() const;

        /**
         * Returns whether the proposed route is empty.
         */
        bool empty() const { return empty_; }

        // The proposed route's clock over the given quantity; empty without
        // a limit or clients.
        template <ClockQuantity Quantity> DriveClock clock() const;

        // missingBreaks() past its rule check. Kept out of line, so that the
        // check inlines into duration() for models without a break rule.
        [[gnu::noinline]] size_t
        missingBreaksUnderRule(ProblemData::VehicleType const &vehType) const;

    public:
        // Every move evaluation builds a Proposal, so its constructor must not
        // become a call. GCC leaves the size and break folds out of line.
        [[gnu::always_inline]] inline Proposal(Segments &&...segments);

        /**
         * The proposal's route. This is the route associated with the first
         * and last segments, and determines the vehicle type and route profile
         * used when evaluating the proposal.
         */
        Route const *route() const;

        /**
         * Returns the (distance cost, excess distance) attributes of the
         * proposed route. The excess here is the whole route beyond
         * ``max_distance``; per-trip violations are reported separately by
         * ``tripExcessDistance()``.
         */
        std::pair<Cost, Distance> distance() const;

        /**
         * Returns the proposed route's distance in excess of
         * ``max_distance_per_trip``, summed over its trips.
         */
        Distance tripExcessDistance() const;

        /**
         * Returns the total location penalty of the proposed route.
         */
        Cost penalty() const;

        /**
         * Returns the (duration cost, time warp) attributes of the proposed
         * route. Clock overrun is priced as the missingBreaks() that would
         * fix it, taken just before the end depot (see Route::summarise()),
         * not as time warp.
         */
        std::pair<Cost, Duration> duration() const;

        /**
         * Returns the breaks the proposed route still lacks: per clock, the
         * stretches' ceil(stretch / limit) - 1, and the larger of the two
         * clocks, since a break resets both. Zero without a break rule.
         */
        size_t missingBreaks() const;

        /**
         * Returns the proposed route's driving in excess of
         * ``max_drive_between_breaks``, summed over its stretches between
         * breaks. Zero when the limit is unset.
         */
        Duration driveClockOverrun() const;

        /**
         * Returns the proposed route's work in excess of
         * ``max_work_between_breaks``, likewise.
         */
        Duration workClockOverrun() const;

        /**
         * Returns the excess load of the proposed route.
         */
        Load excessLoad(size_t dimension) const;
    };

    /**
     * Light wrapper class around a client or depot location. This class tracks
     * the route it is in, and the position and role it currently has in that
     * route.
     */
    class Node
    {
        friend class Route;

        size_t loc_;    // Location represented by this node
        size_t idx_;    // Position in the route
        size_t trip_;   // Trip index.
        Route *route_;  // Indicates membership of a route, if any

    public:
        Node(size_t loc);

        /**
         * Returns the location represented by this node.
         */
        [[nodiscard]] inline size_t client() const;  // TODO rename to loc

        /**
         * Returns this node's position in a route. This value is ``0`` when
         * the node is *not* in a route.
         */
        [[nodiscard]] inline size_t idx() const;

        /**
         * Returns this node's assigned trip number.  This value is ``0`` when
         * the node is *not* in a route.
         */
        [[nodiscard]] inline size_t trip() const;

        /**
         * Returns the route this node is currently in. If the node is not in
         * a route, this returns ``None`` (C++: ``nullptr``).
         */
        [[nodiscard]] inline Route *route() const;

        /**
         * Returns whether this node is a depot.
         */
        [[nodiscard, gnu::always_inline]] inline bool isDepot() const;

        /**
         * Returns whether this node is a start depot.
         */
        [[nodiscard, gnu::always_inline]] inline bool isStartDepot() const;

        /**
         * Returns whether this node is an end depot.
         */
        [[nodiscard, gnu::always_inline]] inline bool isEndDepot() const;

        /**
         * Returns whether this node is a reload depot.
         */
        [[nodiscard, gnu::always_inline]] inline bool isReloadDepot() const;

        /**
         * Assigns the node to the given route, at the given index, in the
         * given trip.
         */
        void assign(Route *route, size_t idx, size_t trip);

        /**
         * Removes the node from its assigned route, if any.
         */
        void unassign();
    };

    /**
     * Forward iterator through the client nodes visited by this route.
     */
    class Iterator
    {
        std::vector<Node *> const *nodes_ = nullptr;
        size_t idx_ = 0;

        // Ensures we skip reload depots.
        void ensureValidIndex();

    public:
        using iterator_category = std::forward_iterator_tag;
        using difference_type = std::ptrdiff_t;
        using value_type = Node *;

        Iterator(std::vector<Node *> const &nodes, size_t idx);

        Iterator() = default;
        Iterator(Iterator const &other) = default;
        Iterator(Iterator &&other) = default;

        Iterator &operator=(Iterator const &other) = default;
        Iterator &operator=(Iterator &&other) = default;

        bool operator==(Iterator const &other) const;

        Node *operator*() const;

        Iterator operator++(int);
        Iterator &operator++();
    };

private:
    using LoadSegments = std::vector<LoadSegment>;

    /**
     * Class storing data related to the route segment starting at ``start``,
     * and ending at the end depot (inclusive).
     */
    class SegmentAfter
    {
        Route const &route_;
        size_t const start;

    public:
        [[gnu::always_inline]] inline Route const *route() const;

        template <bool WithBreaks = true>
        [[gnu::always_inline]] inline bool hasLocation() const;
        template <bool WithBreaks = true>
        [[gnu::always_inline]] inline size_t first() const;  // first non-break
        template <bool WithBreaks = true>
        [[gnu::always_inline]] inline size_t last() const;  // end depot
        [[gnu::always_inline]] inline size_t size() const;
        [[gnu::always_inline]] inline size_t numBreaks() const;

        [[gnu::always_inline]] inline bool startsAtReloadDepot() const;
        [[gnu::always_inline]] inline bool endsAtReloadDepot() const;

        inline SegmentAfter(Route const &route, size_t start);
        template <bool WithBreaks = true>
        inline Distance distance(size_t profile) const;
        inline TripDistance tripDistance(size_t profile) const;
        inline Cost penalty(size_t profile, size_t vehicleType) const;
        template <bool WithBreaks = true>
        inline DurationSegment duration(size_t profile,
                                        size_t vehicleType) const;
        template <ClockQuantity Quantity>
        inline DriveClock clockOver(size_t profile, Duration limit) const;
        DriveClock driveClock(size_t profile, Duration limit) const
        {
            return clockOver<ClockQuantity::Drive>(profile, limit);
        }
        DriveClock workClock(size_t profile, Duration limit) const
        {
            return clockOver<ClockQuantity::Work>(profile, limit);
        }
        inline LoadSegment const &load(size_t dimension) const;
    };

    /**
     * Class storing data related to the route segment starting at the start
     * depot, and ending at ``end`` (inclusive).
     */
    class SegmentBefore
    {
        Route const &route_;
        size_t const end;

    public:
        [[gnu::always_inline]] inline Route const *route() const;

        template <bool WithBreaks = true>
        [[gnu::always_inline]] inline bool hasLocation() const;
        template <bool WithBreaks = true>
        [[gnu::always_inline]] inline size_t first() const;  // start depot
        template <bool WithBreaks = true>
        [[gnu::always_inline]] inline size_t last() const;  // last non-break
        [[gnu::always_inline]] inline size_t size() const;
        [[gnu::always_inline]] inline size_t numBreaks() const;

        [[gnu::always_inline]] inline bool startsAtReloadDepot() const;
        [[gnu::always_inline]] inline bool endsAtReloadDepot() const;

        inline SegmentBefore(Route const &route, size_t end);
        template <bool WithBreaks = true>
        inline Distance distance(size_t profile) const;
        inline TripDistance tripDistance(size_t profile) const;
        inline Cost penalty(size_t profile, size_t vehicleType) const;
        template <bool WithBreaks = true>
        inline DurationSegment duration(size_t profile,
                                        size_t vehicleType) const;
        template <ClockQuantity Quantity>
        inline DriveClock clockOver(size_t profile, Duration limit) const;
        DriveClock driveClock(size_t profile, Duration limit) const
        {
            return clockOver<ClockQuantity::Drive>(profile, limit);
        }
        DriveClock workClock(size_t profile, Duration limit) const
        {
            return clockOver<ClockQuantity::Work>(profile, limit);
        }
        inline LoadSegment const &load(size_t dimension) const;
    };

    /**
     * Class storing data related to the route segment starting at ``start``,
     * and ending at ``end`` (inclusive). The segment must consist of a single
     * trip, possibly including its ending depot.
     */
    class SegmentBetween
    {
        Route const &route_;
        size_t const start;
        size_t const end;

    public:
        [[gnu::always_inline]] inline Route const *route() const;

        template <bool WithBreaks = true>  // false if it holds only breaks
        [[gnu::always_inline]] inline bool hasLocation() const;
        template <bool WithBreaks = true>
        [[gnu::always_inline]] inline size_t first() const;  // first non-break
        template <bool WithBreaks = true>
        [[gnu::always_inline]] inline size_t last() const;  // last non-break
        [[gnu::always_inline]] inline size_t size() const;
        [[gnu::always_inline]] inline size_t numBreaks() const;

        [[gnu::always_inline]] inline bool startsAtReloadDepot() const;
        [[gnu::always_inline]] inline bool endsAtReloadDepot() const;

        inline SegmentBetween(Route const &route, size_t start, size_t end);
        template <bool WithBreaks = true>
        inline Distance distance(size_t profile) const;
        inline TripDistance tripDistance(size_t profile) const;
        inline Cost penalty(size_t profile, size_t vehicleType) const;
        template <bool WithBreaks = true>
        inline DurationSegment duration(size_t profile,
                                        size_t vehicleType) const;

        // duration() over a route that holds breaks, out of line so the
        // break-free case stays small enough to inline.
        [[gnu::noinline]] DurationSegment
        durationWithBreaks(size_t profile, size_t vehicleType) const;

        // Operator segments are a few nodes long, so folding beats prefix
        // lookups that would only hold for this route's own profile and limit.
        DriveClock driveClock(size_t profile, Duration limit) const
        {
            return route_.foldClock<ClockQuantity::Drive>(
                start, end, profile, limit);
        }
        DriveClock workClock(size_t profile, Duration limit) const
        {
            return route_.foldClock<ClockQuantity::Work>(
                start, end, profile, limit);
        }
        inline LoadSegment load(size_t dimension) const;
    };

    ProblemData const &data;

    ProblemData::VehicleType const &vehicleType_;
    size_t const idx_;

    Distance distance_;  // Separately cached cost components
    Cost distanceCost_;
    Cost penaltyCost_;
    Distance excessDistance_;
    Duration duration_;
    Duration overtime_ = 0;
    Cost durationCost_;
    Duration timeWarp_;
    Duration driveExcess_ = 0;  // Travel past max_drive, folded into timeWarp_
    Duration totalClockExcess_ = 0;  // Drive + work clock overrun, likewise
    size_t virtualBreaks_ = 0;       // missing breaks priced in duration_
    Cost reloadCost_;

    // DurationSegment-only values (before forbidden window corrections).
    // Used for consistent delta evaluation in local search, since
    // Proposal::duration() also uses DurationSegment without forbidden windows.
    Cost durationCostDS_;
    Duration timeWarpDS_;

    std::vector<Node> depots_;  // start, end, and reload depots (in that order)

    // Break nodes on this route, kept as nodes come and go, like depots_, so
    // numClients() is right between updates too.
    size_t numBreaks_ = 0;

    // cumBreaks_[idx] is the number of breaks among nodes [0, idx), so it has
    // one entry more than there are nodes. Segments count theirs from it.
    std::vector<size_t> cumBreaks_;

    // Whether the last update() saw a break node. Without one, locs_ is
    // visits and nextReal_ the identity, so the segments skip both lookups.
    bool hasBreaks_ = false;

    std::vector<Node *> nodes;   // Nodes in this route, including depots
    std::vector<size_t> visits;  // Locations in this route, incl. depots

    // Location each node takes in edge lookups: its own, except that a break
    // takes that of the nearest non-break node before it. Prefix structures
    // (cumDist, durBefore) walk these, so a break's edges are matrix(i, i) = 0
    // in and matrix(i, j) out.
    std::vector<size_t> locs_;

    // Index of the first non-break node at or after each index. Always found,
    // since the end depot is never a break. Suffix structures (durAfter) and
    // segments starting at a break measure from here, so they never reach
    // back past their own start for a location.
    std::vector<size_t> nextReal_;

    // nextReal_ and locs_ at idx, without the lookup on a route whose last
    // update() saw no break, where they are the identity and visits. Without
    // WithBreaks the caller knows idx is no break, so neither is looked up.
    template <bool WithBreaks> [[nodiscard]] size_t realAt(size_t idx) const
    {
        return WithBreaks && hasBreaks_ ? nextReal_[idx] : idx;
    }

    template <bool WithBreaks> [[nodiscard]] size_t locAt(size_t idx) const
    {
        return WithBreaks && hasBreaks_ ? locs_[idx] : visits[idx];
    }

    std::vector<Distance> cumDist;  // Dist of start -> node (incl.)

    // Node index at which each trip begins, plus a final entry for the end
    // depot, so trip t spans nodes [tripBounds_[t], tripBounds_[t + 1]]. With
    // no reload depots this is just {0, end}, i.e. one trip.
    std::vector<size_t> tripBounds_;

    // Inclusive prefix sum of each trip's excess over max_distance_per_trip:
    // tripExcess_[t] is the excess of trips [0, t). Lets a segment price the
    // whole trips it spans without walking them.
    std::vector<Distance> tripExcess_;

    // Clock prefix structures, built only while the vehicle type has a break
    // rule. A "reset leg" is a leg between two non-break nodes that carries
    // breaks; stretch r runs from reset leg r (stretch 0 from the start depot)
    // to the start of reset leg r + 1, or to the end depot. Entries 1..m
    // describe the m reset legs; entry 0 is the start depot. Where the reset
    // legs are is shared by both clocks:
    //
    // - resetBounds_: index of the non-break node each reset leg arrives at,
    //   bracketed by 0 and nodes.size() - 1.
    // - legBreaks_: number of breaks on each reset leg.
    // - stretchOf_: number of reset legs arriving at or before each node.
    std::vector<size_t> resetBounds_;
    std::vector<size_t> legBreaks_;
    std::vector<size_t> stretchOf_;

    // What each clock has counted, built only while its limit is finite:
    //
    // - cum: quantity of start -> node (incl.), over locs_; each node's own
    //   clockAt() included, so the carries sit at index 0 and the end depot.
    // - close: cum where each reset leg begins, i.e. where the stretch before
    //   it ends.
    // - start: cum from which the stretch after each reset leg counts: the
    //   leg's end, less the drive left after its pre-paid breaks and less the
    //   arrival node's own quantity.
    // - excess: excess[r] is the clipped excess of the closed stretches
    //   [1, r).
    // - need: need[r] is the breaks those same stretches lack.
    struct ClockPrefix
    {
        std::vector<Duration> cum;
        std::vector<Duration> close;
        std::vector<Duration> start;
        std::vector<Duration> excess;
        std::vector<size_t> need;
    };

    std::array<ClockPrefix, 2> clocks_;  // indexed by ClockQuantity

    template <ClockQuantity Quantity>
    [[nodiscard]] ClockPrefix const &clockPrefix() const
    {
        return clocks_[static_cast<size_t>(Quantity)];
    }

    // The limit of the clock over the given quantity; max() when unset.
    template <ClockQuantity Quantity> [[nodiscard]] Duration breakLimit() const
    {
        return vehicleType_.breakLimit(Quantity);
    }

    // Folds the clock over nodes [start, end] from scratch, for another
    // profile or limit, or for checking the prefix structures.
    template <ClockQuantity Quantity>
    [[nodiscard]] inline DriveClock
    foldClock(size_t start, size_t end, size_t profile, Duration limit) const;

    // This whole route's clock; empty without a limit or clients.
    template <ClockQuantity Quantity>
    [[nodiscard]] inline DriveClock wholeClock() const;

    // Breaks lacking given both clocks: the larger count, as a break resets
    // both. Shared by update() and Proposal::missingBreaks().
    [[nodiscard]] static inline size_t
    missingBreaks(DriveClock const &drive,
                  DriveClock const &work,
                  ProblemData::VehicleType const &vehicleType);

    struct DurationSummary
    {
        Duration duration;
        Duration timeWarp;
        Duration endTime;
    };

    // Duration, time warp and end time of a route whose duration segment is
    // `ds`, with `extra` of missing break time taken just before the end
    // depot: it lengthens the route (max duration, shift, overtime) and is
    // late past `latestEnd`. It pushes no client, so it cannot see waiting it
    // might fill or windows it might break; BreakRepair's real breaks can.
    // Shared by update() and Proposal::duration(), so deltas stay exact.
    // Every evaluation of a model without a break rule passes no extra, so
    // that case stays small enough to inline and the rest is out of line.
    [[nodiscard, gnu::always_inline]] static DurationSummary
    summarise(DurationSegment const &ds,
              Duration maxDuration,
              Duration extra,
              Duration latestEnd)
    {
        if (extra > 0)
            return summariseWithBreaks(ds, maxDuration, extra, latestEnd);

        auto const duration = ds.duration();
        auto const timeWarp = ds.timeWarp(maxDuration);
        return {duration, timeWarp, ds.startEarly() + duration - timeWarp};
    }

    [[nodiscard]] static DurationSummary
    summariseWithBreaks(DurationSegment ds,
                        Duration maxDuration,
                        Duration extra,
                        Duration latestEnd);

    // Number of reset legs, when the clock structures are built.
    [[nodiscard]] inline size_t numResets() const;

    // Builds the clock structures above; a no-op without a break rule.
    void updateClocks();

    template <ClockQuantity Quantity> void updateClock();

    // Trip a node belongs to, as an index into tripBounds_. Node::trip() is
    // not that index for the end depot: clear() assigns it trip 1 on an empty
    // route and every reload bumps it, so it always sits one past the last
    // trip. Everything else -- clients, and reload depots, which belong to the
    // trip they begin -- indexes tripBounds_ directly.
    [[nodiscard]] inline size_t tripOf(size_t idx) const;

    // Exclusive prefix sum of per-location penalties: cumPenalty[i] is the
    // penalty of nodes [0, i), so nodes [a, b] inclusive cost
    // cumPenalty[b + 1] - cumPenalty[a]. Length is nodes.size() + 1.
    std::vector<Cost> cumPenalty;

    // Bit p is set when profile p allows every client currently on this route,
    // and so could take them all. Left fully set on instances that forbid
    // nothing, where it is never read.
    DynamicBitset transferableProfiles_;

    // Load data, for each load dimension. These vectors form matrices, where
    // the rows index the load dimension, and the columns the nodes.
    std::vector<LoadSegments> loadAt;      // Load data at each node
    std::vector<LoadSegments> loadAfter;   // Load of node -> end (incl)
    std::vector<LoadSegments> loadBefore;  // Load of start -> node (incl)

    std::vector<Load> load_;        // Route loads (for each dimension)
    std::vector<Load> excessLoad_;  // Route excess load (for each dimension)

    std::vector<DurationSegment> durAt;      // Duration data at each node
    std::vector<DurationSegment> durAfter;   // Dur of node -> end (incl.)
    std::vector<DurationSegment> durBefore;  // Dur of start -> node (incl.)

#ifndef NDEBUG
    // When debug assertions are enabled, we use this flag to check whether
    // the statistics are still in sync with the route's nodes list. Statistics
    // are only updated after calling ``update()``. If that function has not
    // yet been called after inserting or removing nodes, this flag is active,
    // and asserts on statistics getters will fail.
    bool dirty = false;
#endif

public:
    /**
     * Route index.
     */
    [[nodiscard]] inline size_t idx() const;

    /**
     * @return The client or depot node at the given ``idx``.
     */
    [[nodiscard]] inline Node *operator[](size_t idx);
    [[nodiscard]] inline Node const *operator[](size_t idx) const;

    [[nodiscard]] Iterator begin() const;
    [[nodiscard]] Iterator end() const;

    /**
     * Tests if this route is feasible.
     *
     * @return true if the route is feasible, false otherwise.
     */
    [[nodiscard]] inline bool isFeasible() const;

    /**
     * Determines whether this route is load-feasible.
     *
     * @return true if the route exceeds the capacity, false otherwise.
     */
    [[nodiscard]] inline bool hasExcessLoad() const;

    /**
     * Determines whether this route is distance-feasible.
     *
     * @return true if the route exceeds the maximum distance constraint, false
     *         otherwise.
     */
    [[nodiscard]] inline bool hasExcessDistance() const;

    /**
     * Determines whether this route is time-feasible.
     *
     * @return true if the route has time warp, false otherwise.
     */
    [[nodiscard]] inline bool hasTimeWarp() const;

    /**
     * Total loads on this route.
     */
    [[nodiscard]] inline std::vector<Load> const &load() const;

    /**
     * Pickup or delivery loads in excess of the vehicle's capacity.
     */
    [[nodiscard]] inline std::vector<Load> const &excessLoad() const;

    /**
     * Travel distance in excess of the assigned vehicle type's maximum
     * distance constraint.
     */
    [[nodiscard]] inline Distance excessDistance() const;

    /**
     * Capacity of the vehicle servicing this route.
     */
    [[nodiscard]] inline std::vector<Load> const &capacity() const;

    /**
     * @return The location index of this route's starting depot.
     */
    [[nodiscard]] inline size_t startDepot() const;

    /**
     * @return The location index of this route's ending depot.
     */
    [[nodiscard]] inline size_t endDepot() const;

    /**
     * @return The fixed cost of the vehicle servicing this route.
     */
    [[nodiscard]] inline Cost fixedVehicleCost() const;

    /**
     * @return Total distance travelled on this route.
     */
    [[nodiscard]] inline Distance distance() const;

    /**
     * @return Cost of the distance travelled on this route.
     */
    [[nodiscard]] inline Cost distanceCost() const;

    /**
     * @return Total penalty cost of the locations visited on this route.
     */
    [[nodiscard]] inline Cost penaltyCost() const;

    /**
     * @return Whether the given profile allows every client on this route, and
     *         so could take them all.
     */
    [[nodiscard]] inline bool mayTransferTo(size_t profile) const;

    /**
     * @return Cost per unit of distance travelled on this route.
     */
    [[nodiscard]] inline Cost unitDistanceCost() const;

    /**
     * Returns true if this route has distance-related cost components, either
     * via the objective or via penalised constraints. False otherwise.
     */
    [[nodiscard]] inline bool hasDistanceCost() const;

    /**
     * @return The duration of this route.
     */
    [[nodiscard]] inline Duration duration() const;

    /**
     * @return Overtime of this route.
     */
    [[nodiscard]] inline Duration overtime() const;

    /**
     * @return Cost of this route's duration, including overtime.
     */
    [[nodiscard]] inline Cost durationCost() const;

    /**
     * @return Total reload cost incurred on this route.
     */
    [[nodiscard]] inline Cost reloadCost() const;

    /**
     * @return Cost per unit of duration travelled on this route.
     */
    [[nodiscard]] inline Cost unitDurationCost() const;

    /**
     * @return Cost per unit of overtime on this route.
     */
    [[nodiscard]] inline Cost unitOvertimeCost() const;

    /**
     * Returns true if this route has duration-related cost components, either
     * via the objective or via penalised constraints. False otherwise.
     */
    [[nodiscard]] inline bool hasDurationCost() const;

    /**
     * @return The (soft) maximum shift duration that the vehicle servicing this
     *         route supports. This may optionally be extended with overtime.
     */
    [[nodiscard]] inline Duration shiftDuration() const;

    /**
     * @return The vehicle type data backing this route, used for rules that
     *         depend on more than one of its fields (such as overtime).
     */
    [[nodiscard]] inline ProblemData::VehicleType const &
    vehicleTypeData() const;

    /**
     * @return The (hard) maximum route duration that the vehicle servicing
     *         this route supports.
     */
    [[nodiscard]] inline Duration maxDuration() const;

    /**
     * @return The maximum total travel duration, across trips, that the
     *         vehicle servicing this route supports.
     */
    [[nodiscard]] inline Duration maxDrive() const;

    /**
     * @return The contracted end of shift past which work counts as overtime,
     *         or the maximum representable duration when unset.
     */
    [[nodiscard]] inline Duration overtimeStart() const;

    /**
     * @return The maximum whole-route distance, summed over every trip, that
     *         the vehicle servicing this route supports.
     */
    [[nodiscard]] inline Distance maxDistance() const;

    /**
     * @return The maximum distance of any single trip that the vehicle
     *         servicing this route supports. Independent of maxDistance().
     */
    [[nodiscard]] inline Distance maxDistancePerTrip() const;

    /**
     * @return Total time warp on this route, as the search prices it: clock
     *         overrun is not part of it, but the virtualBreaks() that would
     *         fix it lengthen duration() and can be late at the end depot.
     */
    [[nodiscard]] inline Duration timeWarp() const;

    /**
     * @return The part of timeWarp() that is an actual shift along the
     *         timeline, for deriving clock times. Excludes penalty-only
     *         terms folded into timeWarp() that do not move when the route
     *         starts or ends (today, drive excess past maxDrive()).
     */
    [[nodiscard]] inline Duration timelineTimeWarp() const;

    /**
     * @return The breaks this route still lacks, priced in duration() and
     *         timeWarp() until BreakRepair places real ones.
     */
    [[nodiscard]] inline size_t virtualBreaks() const;

    /**
     * @return The true drive and work clock overrun on this route, summed.
     *         Not part of timeWarp() (see virtualBreaks()); pyvrp::Route
     *         counts it as time warp, apart as clockExcess() (drive) and
     *         workClockExcess().
     */
    [[nodiscard]] inline Duration totalClockExcess() const;

    /**
     * @return The location node ``idx`` takes in edge lookups: its own, or,
     *         for a break, that of the nearest non-break node before it.
     */
    [[nodiscard]] inline size_t location(size_t idx) const;

    /**
     * @return The quantity node ``idx`` does itself: service for work (none
     *         on a break), plus the carries at the start and end depots.
     */
    template <ClockQuantity Quantity>
    [[nodiscard]] inline Duration clockAt(size_t idx) const;

    /**
     * @return Duration cost computed from DurationSegment only (without
     *         forbidden window corrections). Used for consistent delta
     *         evaluation in local search.
     */
    [[nodiscard]] inline Cost durationCostDS() const;

    /**
     * @return Time warp computed from DurationSegment only (without
     *         forbidden window corrections). Used for consistent delta
     *         evaluation in local search.
     */
    [[nodiscard]] inline Duration timeWarpDS() const;

    /**
     * @return The routing profile of the vehicle servicing this route.
     */
    [[nodiscard]] inline size_t profile() const;

    /**
     * @return Whether the vehicle servicing this route has forbidden windows.
     */
    [[nodiscard]] inline bool hasForbiddenWindows() const;

    /**
     * True if this route has no client visits, false otherwise.
     */
    [[nodiscard]] inline bool empty() const;

    /**
     * Number of clients and depots on this route.
     */
    [[nodiscard]] inline size_t size() const;

    /**
     * Number of clients in this route. Breaks are not clients: a route that
     * holds only breaks is empty().
     */
    [[nodiscard]] inline size_t numClients() const;

    /**
     * Number of breaks in this route.
     */
    [[nodiscard]] inline size_t numBreaks() const;

    /**
     * Returns the number of start, end, and reload depots in this route.
     */
    [[nodiscard]] inline size_t numDepots() const;

    /**
     * Returns the number of trips in this route.
     */
    [[nodiscard]] inline size_t numTrips() const;

    /**
     * Returns the maximum number of allowed trips for this route.
     */
    [[nodiscard]] inline size_t maxTrips() const;

    /**
     * Returns an object that can be queried for data associated with the node
     * at idx.
     */
    [[nodiscard]] inline SegmentBetween at(size_t idx) const;

    /**
     * Returns an object that can be queried for data associated with the
     * segment starting at start.
     */
    [[nodiscard]] inline SegmentAfter after(size_t start) const;

    /**
     * Returns an object that can be queried for data associated with the
     * segment ending at end.
     */
    [[nodiscard]] inline SegmentBefore before(size_t end) const;

    /**
     * Returns an object that can be queried for data associated with the
     * segment between [start, end].
     */
    [[nodiscard]] inline SegmentBetween between(size_t start, size_t end) const;

    /**
     * @return This route's vehicle type.
     */
    [[nodiscard]] size_t vehicleType() const;

    /**
     * Clears all clients on this route. After calling this method, ``empty()``
     * returns true.
     */
    void clear();

    /**
     * Reserves capacity for at least given ``size`` number of nodes (depots
     * and clients).
     */
    void reserve(size_t size);

    /**
     * Inserts the given node before index ``idx``. Assumes the given index is
     * valid. Depot nodes are copied into internal memory, but of client nodes
     * no ownership is taken.
     */
    void insert(size_t idx, Node *node);

    /**
     * Appends the given node pointer at the end of the route. Depot nodes are
     * copied into internal memory, but of client nodes no ownership is taken.
     */
    void push_back(Node *node);

    /**
     * Removes the node at ``idx`` from the route. Start and end depots cannot
     * be removed.
     */
    void remove(size_t idx);

    /**
     * Swaps the given nodes.
     */
    static void swap(Node *first, Node *second);

    /**
     * Updates this route. To be called after swapping nodes/changing the
     * solution.
     */
    void update();

    bool operator==(Route const &other) const;
    bool operator==(pyvrp::Route const &other) const;

    Route(ProblemData const &data, size_t idx, size_t vehicleType);
    ~Route();
};

/**
 * Convenience method accessing the node directly before the argument.
 */
inline Route::Node *p(Route::Node *node)
{
    auto &route = *node->route();
    return route[node->idx() - 1];
}

inline Route::Node const *p(Route::Node const *node)
{
    auto const &route = *node->route();
    return route[node->idx() - 1];
}

/**
 * Convenience method accessing the node directly after the argument.
 */
inline Route::Node *n(Route::Node *node)
{
    auto &route = *node->route();
    return route[node->idx() + 1];
}

inline Route::Node const *n(Route::Node const *node)
{
    auto const &route = *node->route();
    return route[node->idx() + 1];
}

size_t Route::Node::client() const { return loc_; }

size_t Route::Node::idx() const { return idx_; }

size_t Route::Node::trip() const { return trip_; }

Route *Route::Node::route() const { return route_; }

bool Route::Node::isDepot() const
{
    return isStartDepot() || isEndDepot() || isReloadDepot();
}

bool Route::Node::isStartDepot() const
{
    return route_ && this == &route_->depots_[0];
}

bool Route::Node::isEndDepot() const
{
    return route_ && this == &route_->depots_[1];
}

bool Route::Node::isReloadDepot() const
{
    // clang-format off
    return route_
        && loc_ < route_->data.numDepots()
        && !isStartDepot()
        && !isEndDepot();
    // clang-format on
}

Route::SegmentAfter::SegmentAfter(Route const &route, size_t start)
    : route_(route), start(start)
{
    assert(start < route.size());
}

Route::SegmentBefore::SegmentBefore(Route const &route, size_t end)
    : route_(route), end(end)
{
    assert(end < route.size());
}

Route::SegmentBetween::SegmentBetween(Route const &route,
                                      size_t start,
                                      size_t end)
    : route_(route), start(start), end(end)
{
    assert(start <= end && end < route.size());

    // The segment must consist of a single trip only, possibly including the
    // depot that begins the next trip (and ends this one). So the difference
    // in trips is at most one.
    assert(route[end]->trip() - route[start]->trip() <= route[end]->isDepot());
}

template <bool WithBreaks>
Distance Route::SegmentAfter::distance([[maybe_unused]] size_t profile) const
{
    assert(profile == route_.profile());
    auto const firstReal = route_.realAt<WithBreaks>(start);
    return {route_.cumDist.back() - route_.cumDist[firstReal]};
}

TripDistance
Route::SegmentAfter::tripDistance([[maybe_unused]] size_t profile) const
{
    assert(profile == route_.profile());

    auto const last = route_.numTrips() - 1;
    auto const trip = route_.tripOf(start);
    auto const startDist = route_.cumDist[route_.realAt<true>(start)];

    if (trip == last)  // then the segment stays inside a single trip
        return {route_.cumDist.back() - startDist, 0, 0, false};

    return {route_.cumDist[route_.tripBounds_[trip + 1]] - startDist,
            route_.tripExcess_[last] - route_.tripExcess_[trip + 1],
            route_.cumDist.back() - route_.cumDist[route_.tripBounds_[last]],
            true};
}

Cost Route::SegmentAfter::penalty([[maybe_unused]] size_t profile,
                                  [[maybe_unused]] size_t vehicleType) const
{
    assert(profile == route_.profile());
    assert(vehicleType == route_.vehicleType());
    assert(start < route_.cumPenalty.size());
    return route_.cumPenalty.back() - route_.cumPenalty[start];
}

template <bool WithBreaks>
DurationSegment
Route::SegmentAfter::duration([[maybe_unused]] size_t profile,
                              [[maybe_unused]] size_t vehicleType) const
{
    assert(profile == route_.profile());
    assert(vehicleType == route_.vehicleType());
    return route_.durAfter[start];
}

template <ClockQuantity Quantity>
DriveClock Route::SegmentAfter::clockOver([[maybe_unused]] size_t profile,
                                          [[maybe_unused]] Duration limit) const
{
    assert(profile == route_.profile());
    assert(limit == route_.breakLimit<Quantity>());

    // Breaks from start up to the first non-break node sit on the leg into
    // this segment. Reset legs arriving at or before that node are outside.
    // The segment counts from before that node's own quantity.
    auto const firstReal = route_.nextReal_[start];
    auto const numResets = route_.numResets();
    auto const outside = route_.stretchOf_[firstReal];
    auto const &prefix = route_.clockPrefix<Quantity>();
    auto const from
        = prefix.cum[firstReal] - route_.clockAt<Quantity>(firstReal);

    DriveClock clock = {.leadRun = firstReal - start};
    if (outside == numResets)
    {
        clock.head = prefix.cum.back() - from;
        clock.tail = clock.head;
        return clock;
    }

    clock.head = prefix.close[outside + 1] - from;
    clock.tail = prefix.cum.back() - prefix.start[numResets];
    clock.resets = numResets - outside;
    clock.excess = prefix.excess[numResets] - prefix.excess[outside + 1];
    clock.need = prefix.need[numResets] - prefix.need[outside + 1];
    return clock;
}

LoadSegment const &Route::SegmentAfter::load(size_t dimension) const
{
    return route_.loadAfter[dimension][start];
}

template <bool WithBreaks>
Distance Route::SegmentBefore::distance([[maybe_unused]] size_t profile) const
{
    assert(profile == route_.profile());
    return route_.cumDist[end];
}

TripDistance
Route::SegmentBefore::tripDistance([[maybe_unused]] size_t profile) const
{
    assert(profile == route_.profile());

    auto const trip = route_.tripOf(end);

    if (trip == 0)  // then the segment stays inside a single trip
        return {route_.cumDist[end], 0, 0, false};

    return {route_.cumDist[route_.tripBounds_[1]],
            route_.tripExcess_[trip] - route_.tripExcess_[1],
            route_.cumDist[end] - route_.cumDist[route_.tripBounds_[trip]],
            true};
}

Cost Route::SegmentBefore::penalty([[maybe_unused]] size_t profile,
                                   [[maybe_unused]] size_t vehicleType) const
{
    assert(profile == route_.profile());
    assert(vehicleType == route_.vehicleType());
    // cumPenalty is an exclusive prefix of length nodes.size() + 1, so the
    // penalty of nodes [0, end] is cumPenalty[end + 1]. The +1 is load-bearing
    // and differs from cumDist, which is an inclusive prefix indexed directly.
    assert(end + 1 < route_.cumPenalty.size());
    return route_.cumPenalty[end + 1];
}

template <bool WithBreaks>
DurationSegment
Route::SegmentBefore::duration([[maybe_unused]] size_t profile,
                               [[maybe_unused]] size_t vehicleType) const
{
    assert(profile == route_.profile());
    assert(vehicleType == route_.vehicleType());
    return route_.durBefore[end];
}

template <ClockQuantity Quantity>
DriveClock
Route::SegmentBefore::clockOver([[maybe_unused]] size_t profile,
                                [[maybe_unused]] Duration limit) const
{
    assert(profile == route_.profile());
    assert(limit == route_.breakLimit<Quantity>());

    // A break at end has cum and stretchOf_ equal to the non-break node before
    // it, so only trailRun differs: the breaks from that node up to end, which
    // sit on reset leg `inside + 1`. cum[0] holds the carry-in.
    auto const &prefix = route_.clockPrefix<Quantity>();
    auto const inside = route_.stretchOf_[end];
    auto const drive = prefix.cum[end];

    DriveClock clock = {.head = drive, .tail = drive, .resets = inside};

    if (route_.data.isBreak(route_.visits[end]))
    {
        auto const arrival = route_.resetBounds_[inside + 1];
        auto const legStart = arrival - route_.legBreaks_[inside + 1] - 1;
        clock.trailRun = end - legStart;
    }

    if (inside > 0)
    {
        clock.head = prefix.close[1];
        clock.tail = drive - prefix.start[inside];
        clock.excess = prefix.excess[inside];
        clock.need = prefix.need[inside];
    }

    return clock;
}

LoadSegment const &Route::SegmentBefore::load(size_t dimension) const
{
    return route_.loadBefore[dimension][end];
}

Route const *Route::SegmentBefore::route() const { return &route_; }

template <bool WithBreaks> bool Route::SegmentBefore::hasLocation() const
{
    return true;
}

template <bool WithBreaks> size_t Route::SegmentBefore::first() const
{
    return route_.visits.front();
}

template <bool WithBreaks> size_t Route::SegmentBefore::last() const
{
    return route_.locAt<WithBreaks>(end);
}

size_t Route::SegmentBefore::size() const { return end + 1; }

size_t Route::SegmentBefore::numBreaks() const
{
    return route_.hasBreaks_ ? route_.cumBreaks_[end + 1] : 0;
}

bool Route::SegmentBefore::startsAtReloadDepot() const { return false; }
bool Route::SegmentBefore::endsAtReloadDepot() const
{
    return route_.nodes[end]->isReloadDepot();
}

Route const *Route::SegmentAfter::route() const { return &route_; }

template <bool WithBreaks> bool Route::SegmentAfter::hasLocation() const
{
    return true;
}

template <bool WithBreaks> size_t Route::SegmentAfter::first() const
{
    return route_.visits[route_.realAt<WithBreaks>(start)];
}

template <bool WithBreaks> size_t Route::SegmentAfter::last() const
{
    return route_.visits.back();
}

size_t Route::SegmentAfter::size() const { return route_.size() - start; }

size_t Route::SegmentAfter::numBreaks() const
{
    return route_.hasBreaks_
               ? route_.cumBreaks_.back() - route_.cumBreaks_[start]
               : 0;
}

bool Route::SegmentAfter::startsAtReloadDepot() const
{
    return route_.nodes[start]->isReloadDepot();
}
bool Route::SegmentAfter::endsAtReloadDepot() const { return false; }

Route const *Route::SegmentBetween::route() const { return &route_; }

template <bool WithBreaks> bool Route::SegmentBetween::hasLocation() const
{
    return route_.realAt<WithBreaks>(start) <= end;
}

template <bool WithBreaks> size_t Route::SegmentBetween::first() const
{
    assert(hasLocation());
    return route_.visits[route_.realAt<WithBreaks>(start)];
}

template <bool WithBreaks> size_t Route::SegmentBetween::last() const
{
    // With a non-break node in the segment, the nearest one at or before end
    // lies inside it, so the backward alias does not escape the segment.
    assert(hasLocation());
    return route_.locAt<WithBreaks>(end);
}

size_t Route::SegmentBetween::size() const { return end - start + 1; }

size_t Route::SegmentBetween::numBreaks() const
{
    return route_.hasBreaks_
               ? route_.cumBreaks_[end + 1] - route_.cumBreaks_[start]
               : 0;
}

bool Route::SegmentBetween::startsAtReloadDepot() const
{
    return route_.nodes[start]->isReloadDepot();
}
bool Route::SegmentBetween::endsAtReloadDepot() const
{
    return route_.nodes[end]->isReloadDepot();
}

template <bool WithBreaks>
Distance Route::SegmentBetween::distance(size_t profile) const
{
    if (!hasLocation<WithBreaks>())
        return 0;

    // Leading breaks are skipped: the edge into them belongs to whatever
    // precedes the segment, and is added by the Proposal fold.
    auto const firstReal = route_.realAt<WithBreaks>(start);

    if (profile != route_.profile())  // then we have to compute the distance
    {                                 // segment from scratch.
        auto const &mat = route_.data.distanceMatrix(profile);
        Distance distance = 0;

        for (size_t step = firstReal; step != end; ++step)
        {
            auto const from = route_.locAt<WithBreaks>(step);
            auto const to = route_.locAt<WithBreaks>(step + 1);
            assert(!route_.data.isBreak(from) && !route_.data.isBreak(to));
            distance += mat(from, to);
        }

        return distance;
    }

    auto const startDist = route_.cumDist[firstReal];
    auto const endDist = route_.cumDist[end];

    assert(startDist <= endDist);
    return endDist - startDist;
}

TripDistance Route::SegmentBetween::tripDistance(size_t profile) const
{
    // A SegmentBetween is a single trip by construction -- at most it also
    // carries the depot that ends it, which is a boundary at the edge rather
    // than inside. So it never splits, and endsAtReloadDepot() is what tells
    // the fold that the trip closes here.
    return {distance(profile), 0, 0, false};
}

Cost Route::SegmentBetween::penalty(size_t profile, size_t vehicleType) const
{
    // SegmentBetween is the segment type that crosses routes, and therefore
    // profiles and vehicle types, so it is the one that must be able to
    // recompute. Note the inclusive bound: penalties are node-additive. A
    // vehicle type change only matters when some location is locked, so an
    // instance without locks keeps the prefix-sum fast path across types.
    auto const lockChanges
        = route_.data.hasVehicleLocks() && vehicleType != route_.vehicleType();

    if (profile != route_.profile() || lockChanges)
    {
        auto const &pen = route_.data.penalties(profile);
        Cost penalty = 0;

        for (size_t step = start; step <= end; ++step)
        {
            auto const location = route_.visits[step];
            penalty += pen[location]
                       + route_.data.lockPenalty(vehicleType, location);
        }

        return penalty;
    }

    assert(start < route_.cumPenalty.size());
    assert(end + 1 < route_.cumPenalty.size());
    return route_.cumPenalty[end + 1] - route_.cumPenalty[start];
}

template <bool WithBreaks>
DurationSegment Route::SegmentBetween::duration(size_t profile,
                                                size_t vehicleType) const
{
    auto const &mat = route_.data.durationMatrix(profile);

    if (WithBreaks && route_.hasBreaks_)
        return durationWithBreaks(profile, vehicleType);

    auto durSegment = route_.durAt[start];
    for (size_t step = start; step != end; ++step)
        durSegment = DurationSegment::merge(
            mat(route_.visits[step], route_.visits[step + 1]),
            durSegment,
            route_.durAt[step + 1]);

    return durSegment;
}

LoadSegment Route::SegmentBetween::load(size_t dimension) const
{
    auto const &loads = route_.loadAt[dimension];

    auto loadSegment = loads[start];
    for (size_t step = start; step != end; ++step)
        loadSegment = LoadSegment::merge(loadSegment, loads[step + 1]);

    return loadSegment;
}

bool Route::isFeasible() const
{
    assert(!dirty);
    return !hasExcessLoad() && !hasTimeWarp() && !hasExcessDistance();
}

bool Route::hasExcessLoad() const
{
    assert(!dirty);
    return std::any_of(excessLoad_.begin(),
                       excessLoad_.end(),
                       [](auto const excess) { return excess > 0; });
}

bool Route::hasExcessDistance() const
{
    assert(!dirty);
    return excessDistance() > 0;
}

bool Route::hasTimeWarp() const
{
    assert(!dirty);
    return timeWarp() > 0;
}

size_t Route::idx() const { return idx_; }

Route::Node *Route::operator[](size_t idx)
{
    assert(idx < nodes.size());
    return nodes[idx];
}

Route::Node const *Route::operator[](size_t idx) const
{
    assert(idx < nodes.size());
    return nodes[idx];
}

std::vector<Load> const &Route::load() const
{
    assert(!dirty);
    return load_;
}

std::vector<Load> const &Route::excessLoad() const
{
    assert(!dirty);
    return excessLoad_;
}

Distance Route::excessDistance() const
{
    assert(!dirty);
    return excessDistance_;
}

std::vector<Load> const &Route::capacity() const
{
    return vehicleType_.capacity;
}

size_t Route::startDepot() const { return vehicleType_.startDepot; }

size_t Route::endDepot() const { return vehicleType_.endDepot; }

Cost Route::fixedVehicleCost() const { return vehicleType_.fixedCost; }

Distance Route::distance() const
{
    assert(!dirty);
    return distance_;
}

Cost Route::distanceCost() const
{
    assert(!dirty);
    return distanceCost_;
}

Cost Route::penaltyCost() const
{
    assert(!dirty);
    return penaltyCost_;
}

bool Route::mayTransferTo(size_t profile) const
{
    assert(!dirty);
    assert(profile < transferableProfiles_.size());
    return transferableProfiles_[profile];
}

Cost Route::unitDistanceCost() const { return vehicleType_.unitDistanceCost; }

bool Route::hasDistanceCost() const
{
    // Every distance constraint must be named here. This gates whether
    // CostEvaluator::deltaCost prices distance at all, so a cap missing from
    // this disjunction is a cap local search never sees: it will create and
    // worsen violations for free. That is the bug fixed for overtime in
    // v0.8.0, and max_distance_per_trip is exposed to it in the most likely
    // configuration of all -- a per-trip cap with max_distance left unset.
    return unitDistanceCost() != 0
           || maxDistance() != std::numeric_limits<Distance>::max()
           || maxDistancePerTrip() != std::numeric_limits<Distance>::max();
}

Duration Route::duration() const
{
    assert(!dirty);
    return duration_;
}

Duration Route::overtime() const
{
    assert(!dirty);
    return overtime_;
}

Cost Route::durationCost() const
{
    assert(!dirty);
    return durationCost_;
}

Cost Route::reloadCost() const
{
    assert(!dirty);
    return reloadCost_;
}

Cost Route::unitDurationCost() const { return vehicleType_.unitDurationCost; }

Cost Route::unitOvertimeCost() const { return vehicleType_.unitOvertimeCost; }

bool Route::hasDurationCost() const
{
    // Overtime is reachable either from a contracted end of shift, or from a
    // finite nominal shift the route can be costed for running past. Missing
    // the latter would leave delta evaluation blind to overtime whenever the
    // hard cap is unbounded.
    auto const unbounded = std::numeric_limits<Duration>::max();
    auto const hasOvertimeCost
        = unitOvertimeCost() != 0
          && (overtimeStart() != unbounded || shiftDuration() != unbounded);

    // clang-format off
    return data.hasTimeWindows()
        || unitDurationCost() != 0
        || hasOvertimeCost
        || maxDuration() != unbounded
        || maxDrive() != unbounded
        || vehicleType_.hasBreakRule();
    // clang-format on
}

Duration Route::shiftDuration() const { return vehicleType_.shiftDuration; }

ProblemData::VehicleType const &Route::vehicleTypeData() const
{
    return vehicleType_;
}

Duration Route::maxDuration() const { return vehicleType_.maxDuration; }

Duration Route::maxDrive() const { return vehicleType_.maxDrive; }

size_t Route::numResets() const
{
    assert(resetBounds_.size() >= 2);
    return resetBounds_.size() - 2;
}

template <ClockQuantity Quantity> Duration Route::clockAt(size_t idx) const
{
    if constexpr (Quantity == ClockQuantity::Drive)
        return idx == 0 ? vehicleType_.driveCarryIn : 0;
    else
    {
        if (idx == 0)
            return vehicleType_.workCarryIn;

        if (idx == nodes.size() - 1)
            return vehicleType_.workAfterEnd;

        auto const loc = visits[idx];
        if (loc < data.numDepots())  // reload depot
            return static_cast<ProblemData::Depot const &>(data.location(loc))
                .serviceDuration;

        ProblemData::Client const &client = data.location(loc);
        return client.serviceDuration;  // zero for a break (see Client)
    }
}

template <ClockQuantity Quantity>
DriveClock
Route::foldClock(size_t start, size_t end, size_t profile, Duration limit) const
{
    // Breaks before the first non-break node sit on the leg into the segment,
    // and breaks after the last on the leg out of it: the fold only counts
    // them, as leadRun and trailRun.
    auto const firstReal = nextReal_[start];
    if (firstReal > end)
        return {.leadRun = end - start + 1, .trailRun = end - start + 1};

    auto const &mat = data.durationMatrix(profile);
    auto const at = [&](size_t idx) -> DriveClock
    {
        auto const own = clockAt<Quantity>(idx);
        return {.head = own, .tail = own};
    };

    DriveClock clock = at(firstReal);
    clock.leadRun = firstReal - start;
    for (size_t idx = firstReal + 1; idx <= end; ++idx)
    {
        if (data.isBreak(visits[idx]))
            clock.trailRun++;
        else
            clock = DriveClock::merge(
                clock, mat(locs_[idx - 1], visits[idx]), at(idx), limit);
    }

    return clock;
}

template <ClockQuantity Quantity> DriveClock Route::wholeClock() const
{
    auto const limit = breakLimit<Quantity>();
    if (limit == std::numeric_limits<Duration>::max() || empty())
        return {};  // as Proposal::clock(), which skips empty routes

    auto const last = SegmentBefore(*this, nodes.size() - 1);
    return clockOf<Quantity>(last, profile(), limit);
}

size_t Route::missingBreaks(DriveClock const &drive,
                            DriveClock const &work,
                            ProblemData::VehicleType const &vehicleType)
{
    return std::max(drive.missing(vehicleType.breakLimit(ClockQuantity::Drive)),
                    work.missing(vehicleType.breakLimit(ClockQuantity::Work)));
}

Duration Route::overtimeStart() const { return vehicleType_.overtimeStart; }

Distance Route::maxDistance() const { return vehicleType_.maxDistance; }

Distance Route::maxDistancePerTrip() const
{
    return vehicleType_.maxDistancePerTrip;
}

size_t Route::tripOf(size_t idx) const
{
    return std::min(nodes[idx]->trip(), numTrips() - 1);
}

Duration Route::timeWarp() const
{
    assert(!dirty);
    return timeWarp_;
}

Duration Route::timelineTimeWarp() const
{
    assert(!dirty);
    return timeWarp_ - driveExcess_;
}

size_t Route::virtualBreaks() const
{
    assert(!dirty);
    return virtualBreaks_;
}

Duration Route::totalClockExcess() const
{
    assert(!dirty);
    return totalClockExcess_;
}

size_t Route::location(size_t idx) const
{
    assert(!dirty);
    assert(idx < locs_.size());
    return locs_[idx];
}

Cost Route::durationCostDS() const
{
    assert(!dirty);
    return durationCostDS_;
}

Duration Route::timeWarpDS() const
{
    assert(!dirty);
    return timeWarpDS_;
}

size_t Route::profile() const { return vehicleType_.profile; }

bool Route::hasForbiddenWindows() const
{
    return !vehicleType_.forbiddenWindows.empty();
}

bool Route::empty() const { return numClients() == 0; }

size_t Route::size() const { return nodes.size(); }

size_t Route::numClients() const { return size() - numDepots() - numBreaks_; }

size_t Route::numBreaks() const { return numBreaks_; }

size_t Route::numDepots() const { return depots_.size(); }

size_t Route::numTrips() const { return depots_.size() - 1; }

size_t Route::maxTrips() const { return vehicleType_.maxTrips(); }

Route::SegmentBetween Route::at(size_t idx) const
{
    assert(!dirty);
    return {*this, idx, idx};
}

Route::SegmentAfter Route::after(size_t start) const
{
    assert(!dirty);
    return {*this, start};
}

Route::SegmentBefore Route::before(size_t end) const
{
    assert(!dirty);
    return {*this, end};
}

Route::SegmentBetween Route::between(size_t start, size_t end) const
{
    assert(!dirty);
    return {*this, start, end};
}

template <Segment... Segments>
Route::Proposal<Segments...>::Proposal(Segments &&...segments)
    : segments_(std::forward<Segments>(segments)...)
{
    static_assert(sizeof...(Segments) > 0, "Proposal cannot be empty.");

    // Empty if the proposal holds only the start and end depot, and breaks:
    // those are placed for clients, so without clients they go too.
    auto const numBreaks = route()->data.hasBreaks() ? countBreaks() : 0;
    empty_ = size() - numBreaks == 2;
    withBreaks_ = numBreaks > 0;

    [[maybe_unused]] auto &&first = std::get<0>(segments_);
    [[maybe_unused]] auto &&last = std::get<sizeof...(Segments) - 1>(segments_);
    assert(first.route() == last.route());  // must start and end at same route

    [[maybe_unused]] auto const *route = this->route();
    assert(first.first() == route->startDepot());  // must start at route start
    assert(last.last() == route->endDepot());      // must end at route end
}

template <Segment... Segments> size_t Route::Proposal<Segments...>::size() const
{
    return std::apply([](auto &&...args) { return (args.size() + ...); },
                      segments_);
}

template <Segment... Segments>
size_t Route::Proposal<Segments...>::countBreaks() const
{
    return std::apply([](auto &&...args) { return (args.numBreaks() + ...); },
                      segments_);
}

template <Segment... Segments>
Route const *Route::Proposal<Segments...>::route() const
{
    return std::get<0>(segments_).route();
}

template <Segment... Segments>
std::pair<Cost, Distance> Route::Proposal<Segments...>::distance() const
{
    if (empty())
        return std::make_pair(0, 0);

    return withBreaks_ ? distanceWithBreaks() : foldDistance<false>();
}

template <Segment... Segments>
std::pair<Cost, Distance>
Route::Proposal<Segments...>::distanceWithBreaks() const
{
    return foldDistance<true>();
}

template <Segment... Segments>
template <bool WithBreaks>
std::pair<Cost, Distance> Route::Proposal<Segments...>::foldDistance() const
{
    auto const &data = route()->data;
    auto const unitDistanceCost = route()->unitDistanceCost();
    auto const maxDistance = route()->maxDistance();
    auto const profile = route()->profile();
    auto const &matrix = data.distanceMatrix(profile);

    auto const fn = [&](auto &&segment, auto &&...args)
    {
        auto distance = segment.template distance<WithBreaks>(profile);
        auto last = segment.template last<WithBreaks>();

        auto const merge = [&](auto const &self, auto &&other, auto &&...args)
        {
            // A segment of only breaks has no distance and no location, so
            // the edge runs from `last` straight to the next located segment.
            if (other.template hasLocation<WithBreaks>())
            {
                auto const first = other.template first<WithBreaks>();
                assert(!data.isBreak(last) && !data.isBreak(first));
                distance += matrix(last, first)
                            + other.template distance<WithBreaks>(profile);
                last = other.template last<WithBreaks>();
            }

            if constexpr (sizeof...(args) != 0)
                self(self, std::forward<decltype(args)>(args)...);
        };

        merge(merge, std::forward<decltype(args)>(args)...);

        auto const excess = std::max<Distance>(distance - maxDistance, 0);
        auto const cost = unitDistanceCost * static_cast<Cost>(distance);
        return std::make_pair(cost, excess);
    };

    return std::apply(fn, segments_);
}

template <Segment... Segments>
Distance Route::Proposal<Segments...>::tripExcessDistance() const
{
    // Checked before empty(), which folds size() over the whole segment pack.
    // hasDistanceCost() is true for anyone paying per unit of distance, so
    // deltaCost reaches this on every evaluation, and for every model that
    // leaves the cap unset the answer is a single load and compare away.
    auto const maxPerTrip = route()->maxDistancePerTrip();

    if (maxPerTrip == std::numeric_limits<Distance>::max())
        return 0;

    if (empty())
        return 0;

    auto const &data = route()->data;
    auto const profile = route()->profile();
    auto const &matrix = data.distanceMatrix(profile);

    auto const clip = [&](Distance distance)
    { return std::max<Distance>(distance - maxPerTrip, 0); };

    auto const fn = [&](auto &&segment, auto &&...args)
    {
        // `head` is the first trip and `tail` the one still open at the right
        // edge; before the first boundary is seen the two are the same trip
        // and only `head` is used. Both stay unclipped until the fold ends,
        // because either can still grow when the next segment is appended.
        auto acc = segment.tripDistance(profile);

        auto const close = [&]  // the open trip ends here
        {
            if (acc.split)
                acc.excess += clip(acc.tail);

            acc.split = true;
            acc.tail = 0;
        };

        auto const extend = [&](Distance distance)
        { (acc.split ? acc.tail : acc.head) += distance; };

        auto const append = [&](TripDistance const &next)
        {
            extend(next.head);

            if (!next.split)
                return;

            close();  // `next`'s first boundary closes the open trip
            acc.excess += next.excess;
            acc.tail = next.tail;
        };

        auto last = segment.last();
        if (segment.endsAtReloadDepot())
            close();

        auto const merge = [&](auto const &self, auto &&other, auto &&...args)
        {
            // The edge into a reload depot is the closing leg of the trip that
            // ends there, not the opening leg of the next one, so it is added
            // before the boundary closes. This matches update(), where trip t
            // measures cumDist[bounds[t + 1]] - cumDist[bounds[t]] and so
            // carries its own arrival edge. A segment of only breaks adds
            // nothing and cannot hold a boundary, so `last` carries through.
            if (other.hasLocation())
            {
                assert(!data.isBreak(last) && !data.isBreak(other.first()));
                extend(matrix(last, other.first()));

                if (other.startsAtReloadDepot())
                    close();

                append(other.tripDistance(profile));
                last = other.last();
            }

            if constexpr (sizeof...(args) != 0)
            {
                // Only when the segment is more than the depot itself, which
                // already closed the trip above. Mirrors Proposal::excessLoad.
                if (other.endsAtReloadDepot() && other.size() > 1)
                    close();

                self(self, std::forward<decltype(args)>(args)...);
            }
        };

        merge(merge, std::forward<decltype(args)>(args)...);

        return acc.excess + clip(acc.head) + (acc.split ? clip(acc.tail) : 0);
    };

    return std::apply(fn, segments_);
}

template <Segment... Segments>
Cost Route::Proposal<Segments...>::penalty() const
{
    if (empty())
        return 0;

    auto const profile = route()->profile();
    auto const vehicleType = route()->vehicleType();

    // Penalties and locks are node-additive, so unlike distance there is no
    // cross-edge term between consecutive segments and this is a plain fold.
    auto const fn = [&](auto &&...segments)
    { return (segments.penalty(profile, vehicleType) + ...); };

    return std::apply(fn, segments_);
}

template <Segment... Segments>
std::pair<Cost, Duration> Route::Proposal<Segments...>::duration() const
{
    if (empty())
        return std::make_pair(0, 0);

    return withBreaks_ ? durationWithBreaks() : foldDuration<false>();
}

template <Segment... Segments>
std::pair<Cost, Duration>
Route::Proposal<Segments...>::durationWithBreaks() const
{
    return foldDuration<true>();
}

template <Segment... Segments>
template <bool WithBreaks>
std::pair<Cost, Duration> Route::Proposal<Segments...>::foldDuration() const
{
    auto const &data = route()->data;
    auto const unitDurationCost = route()->unitDurationCost();
    auto const unitOvertimeCost = route()->unitOvertimeCost();
    auto const &vehType = route()->vehicleTypeData();
    auto const maxDuration = route()->maxDuration();
    auto const maxDrive = route()->maxDrive();
    auto const profile = route()->profile();
    auto const vehicleType = route()->vehicleType();
    auto const &matrix = data.durationMatrix(profile);
    auto const extra
        = static_cast<Duration>(missingBreaks()) * vehType.breakDuration;
    auto const latestEnd = extra > 0 ? route()->durAt.back().startLate() : 0;

    // Finalising is expensive with duration segments. However, finaliseFront is
    // significantly less expensive than finaliseBack. To use it, we iterate the
    // segments in reverse (right to left, rather than default left to right).
    auto const fn = [&](auto &&segment, auto &&...args)
    {
        auto ds = segment.template duration<WithBreaks>(profile, vehicleType);
        auto first = segment.template first<WithBreaks>();

        if (segment.startsAtReloadDepot())
            ds = ds.finaliseFront();

        auto const merge = [&](auto const &self, auto &&other, auto &&...args)
        {
            // A segment of only breaks has no edge and cannot end at a reload
            // depot, so it merges in directly and `first` carries through to
            // the next located segment on the left.
            auto const hasLocation = other.template hasLocation<WithBreaks>();
            assert(!hasLocation
                   || (!data.isBreak(other.template last<WithBreaks>())
                       && !data.isBreak(first)));
            Duration edgeDur
                = hasLocation ? matrix(other.template last<WithBreaks>(), first)
                              : 0;

            if (other.endsAtReloadDepot())
            {
                // The other segment ends at a reload depot, so we go there and
                // finalise the current segment. We first travel there. We need
                // to end the segment within the depot's time windows to
                // properly account for any release time on our segment.
                //
                // If the segment comes from a route (other.route() != nullptr),
                // its duration() already includes the depot's service time.
                // If not (e.g., ReloadDepotSegment), we need to add it here.
                if (other.route() == nullptr)
                {
                    ProblemData::Depot const &depot
                        = data.location(other.template last<WithBreaks>());
                    DurationSegment const depotDS(
                        depot.serviceDuration,
                        0,
                        0,
                        std::numeric_limits<Duration>::max(),
                        0);
                    ds = DurationSegment::merge(edgeDur, depotDS, ds);
                    edgeDur = 0;  // we are already there!
                }
                ds = ds.finaliseFront();
            }

            ds = DurationSegment::merge(
                edgeDur,
                other.template duration<WithBreaks>(profile, vehicleType),
                ds);
            if (hasLocation)
                first = other.template first<WithBreaks>();

            if constexpr (sizeof...(args) != 0)
            {
                if (other.startsAtReloadDepot() && other.size() > 1)
                    // Only when the segment contains more than just the depot.
                    // Checking for size speeds up the common case of a reload
                    // depot insertion.
                    ds = ds.finaliseFront();

                self(self, std::forward<decltype(args)>(args)...);
            }
        };

        merge(merge, std::forward<decltype(args)>(args)...);

        auto const [duration, timeWarp, endTime]
            = summarise(ds, maxDuration, extra, latestEnd);
        auto const overtime = vehType.overtime(endTime, duration);
        auto const cost = unitDurationCost * static_cast<Cost>(duration)
                          + unitOvertimeCost * static_cast<Cost>(overtime);
        // Drive excess is penalty-only, so it joins the time warp only after
        // endTime and overtime are derived above.
        return std::make_pair(cost, timeWarp + ds.driveExcess(maxDrive));
    };

    return std::apply(fn, detail::reverse(segments_));
}

template <Segment... Segments>
Duration Route::Proposal<Segments...>::driveClockOverrun() const
{
    auto const limit = route()->template breakLimit<ClockQuantity::Drive>();
    return clock<ClockQuantity::Drive>().overrun(limit);
}

template <Segment... Segments>
Duration Route::Proposal<Segments...>::workClockOverrun() const
{
    auto const limit = route()->template breakLimit<ClockQuantity::Work>();
    return clock<ClockQuantity::Work>().overrun(limit);
}

template <Segment... Segments>
size_t Route::Proposal<Segments...>::missingBreaks() const
{
    auto const &vehType = route()->vehicleTypeData();
    if (!vehType.hasBreakRule())  // models without one pay a load and compare
        return 0;

    return missingBreaksUnderRule(vehType);
}

template <Segment... Segments>
size_t Route::Proposal<Segments...>::missingBreaksUnderRule(
    ProblemData::VehicleType const &vehType) const
{
    return Route::missingBreaks(
        clock<ClockQuantity::Drive>(), clock<ClockQuantity::Work>(), vehType);
}

template <Segment... Segments>
template <ClockQuantity Quantity>
DriveClock Route::Proposal<Segments...>::clock() const
{
    // Checked first, as in tripExcessDistance(): models without a break rule
    // pay one load and compare.
    auto const limit = route()->template breakLimit<Quantity>();

    if (limit == std::numeric_limits<Duration>::max())
        return {};

    if (empty())
        return {};

    auto const &data = route()->data;
    auto const profile = route()->profile();
    auto const &matrix = data.durationMatrix(profile);

    // The carries come in with the first and last segments, which are the
    // route's own start and end (see Route::clockAt()).
    auto const fn = [&](auto &&segment, auto &&...args)
    {
        assert(segment.hasLocation());  // starts at the start depot
        auto clock = clockOf<Quantity>(segment, profile, limit);
        auto last = segment.last();

        auto const merge = [&](auto const &self, auto &&other, auto &&...args)
        {
            auto const next = clockOf<Quantity>(other, profile, limit);

            // A segment of only breaks has no location: its breaks join the
            // leg from `last` to the next located segment.
            if (other.hasLocation())
            {
                assert(!data.isBreak(last) && !data.isBreak(other.first()));
                auto const edge = matrix(last, other.first());
                clock = DriveClock::merge(clock, edge, next, limit);
                last = other.last();
            }
            else
                clock.trailRun += next.trailRun;

            if constexpr (sizeof...(args) != 0)
                self(self, std::forward<decltype(args)>(args)...);
        };

        merge(merge, std::forward<decltype(args)>(args)...);
        return clock;
    };

    return std::apply(fn, segments_);
}

template <Segment... Segments>
Load Route::Proposal<Segments...>::excessLoad(size_t dimension) const
{
    if (empty())
        return 0;

    auto const &capacities = route()->capacity();
    auto const capacity = capacities[dimension];

    auto const fn = [&](auto &&segment, auto &&...args)
    {
        auto ls = segment.load(dimension);
        if (segment.endsAtReloadDepot())
            ls = ls.finalise(capacity);

        auto const merge = [&](auto const &self, auto &&other, auto &&...args)
        {
            if (other.startsAtReloadDepot())
                ls = ls.finalise(capacity);

            ls = LoadSegment::merge(ls, other.load(dimension));

            if constexpr (sizeof...(args) != 0)
            {
                if (other.endsAtReloadDepot() && other.size() > 1)
                    // Only when the segment contains more than just the depot.
                    // Checking for size speeds up the common case of a reload
                    // depot insertion.
                    ls = ls.finalise(capacity);

                self(self, std::forward<decltype(args)>(args)...);
            }
        };

        merge(merge, std::forward<decltype(args)>(args)...);
        return ls.excessLoad(capacity);
    };

    return std::apply(fn, segments_);
}
}  // namespace pyvrp::search

// Outputs a route into a given ostream in human-readable format
std::ostream &operator<<(std::ostream &out, pyvrp::search::Route const &route);

std::ostream &operator<<(std::ostream &out,  // for debugging
                         pyvrp::search::Route::Node const &node);

#endif  // PYVRP_SEARCH_ROUTE_H

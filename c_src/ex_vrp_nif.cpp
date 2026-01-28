/**
 * ExVrp NIF - Elixir bindings for PyVRP C++ core
 *
 * Uses the Fine library for ergonomic C++ to Elixir interop.
 */

#include <fine.hpp>

#include "pyvrp/CostEvaluator.h"
#include "pyvrp/DynamicBitset.h"
#include "pyvrp/LoadSegment.h"
#include "pyvrp/ProblemData.h"
#include "pyvrp/RandomNumberGenerator.h"
#include "pyvrp/Solution.h"
#include "pyvrp/search/Exchange.h"
#include "pyvrp/search/LocalSearch.h"
#include "pyvrp/search/PerturbationManager.h"
#include "pyvrp/search/RelocateWithDepot.h"
#include "pyvrp/search/SwapRoutes.h"
#include "pyvrp/search/SwapStar.h"
#include "pyvrp/search/SwapTails.h"
#include "pyvrp/search/primitives.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>
#include <set>
#include <string>
#include <tuple>
#include <vector>

using namespace pyvrp;

// Forward declarations
std::string decode_binary_to_string([[maybe_unused]] ErlNifEnv *env,
                                    ERL_NIF_TERM term);

// -----------------------------------------------------------------------------
// Resource Types
// -----------------------------------------------------------------------------

// Wrap ProblemData in a shared_ptr for resource management
struct ProblemDataResource
{
    std::shared_ptr<ProblemData> data;

    explicit ProblemDataResource(std::shared_ptr<ProblemData> d)
        : data(std::move(d))
    {
    }
};

// Wrap Solution for resource management
struct SolutionResource
{
    Solution solution;
    std::shared_ptr<ProblemData> problemData;  // Keep problem data alive

    SolutionResource(Solution s, std::shared_ptr<ProblemData> pd)
        : solution(std::move(s)), problemData(std::move(pd))
    {
    }
};

// Wrap CostEvaluator for resource management
struct CostEvaluatorResource
{
    CostEvaluator evaluator;

    CostEvaluatorResource(std::vector<double> loadPenalties,
                          double twPenalty,
                          double distPenalty)
        : evaluator(std::move(loadPenalties), twPenalty, distPenalty)
    {
    }
};

// Forward declaration
struct SearchRouteData;

// Shared data for search::Route - allows nodes to keep the route alive
// Member order matters for destruction: route is destroyed first (calls
// clear()), then ownedNodes is destroyed (deletes nodes). This ensures nodes
// are alive when Route::~Route() iterates over them.
struct SearchRouteData
{
    std::shared_ptr<ProblemData> problemData;  // Keep problem data alive
    std::vector<std::unique_ptr<search::Route::Node>>
        ownedNodes;  // Nodes we own
    std::unique_ptr<search::Route>
        route;  // Destroyed first (reverse declaration order)

    SearchRouteData(std::unique_ptr<search::Route> r,
                    std::shared_ptr<ProblemData> pd)
        : problemData(std::move(pd)), route(std::move(r))
    {
    }

    // Default destructor is fine - members destroyed in reverse order:
    // 1. route destroyed -> Route::~Route() calls clear(), nodes still alive
    // 2. ownedNodes destroyed -> nodes deleted
    // 3. problemData destroyed
};

// Wrap search::Route for resource management
struct SearchRouteResource
{
    std::shared_ptr<SearchRouteData> data;

    SearchRouteResource(std::unique_ptr<search::Route> r,
                        std::shared_ptr<ProblemData> pd)
        : data(std::make_shared<SearchRouteData>(std::move(r), std::move(pd)))
    {
    }

    // Convenience accessors
    search::Route *route() { return data->route.get(); }
    std::shared_ptr<ProblemData> &problemData() { return data->problemData; }
    std::vector<std::unique_ptr<search::Route::Node>> &ownedNodes()
    {
        return data->ownedNodes;
    }
};

// Wrap search::Route::Node for resource management
struct SearchNodeResource
{
    search::Route::Node
        *node;   // Pointer to node (may be owned by route or by us)
    bool owned;  // Whether we own this node
    std::shared_ptr<ProblemData> problemData;  // Keep problem data alive
    std::shared_ptr<SearchRouteData>
        parentRoute;  // Keep parent route alive (if node is from a route)

    // Constructor for standalone nodes (owned by us)
    SearchNodeResource(search::Route::Node *n,
                       bool o,
                       std::shared_ptr<ProblemData> pd)
        : node(n), owned(o), problemData(std::move(pd)), parentRoute(nullptr)
    {
    }

    // Constructor for nodes from a route (keeps route alive)
    SearchNodeResource(search::Route::Node *n,
                       std::shared_ptr<SearchRouteData> parent)
        : node(n),
          owned(false),
          problemData(parent->problemData),
          parentRoute(std::move(parent))
    {
    }

    ~SearchNodeResource()
    {
        if (owned && node)
        {
            delete node;
        }
    }
};

// Wrap Exchange operators for resource management
template <size_t N, size_t M> struct ExchangeOperatorResource
{
    std::unique_ptr<search::Exchange<N, M>> op;
    std::shared_ptr<ProblemData> problemData;

    ExchangeOperatorResource(std::unique_ptr<search::Exchange<N, M>> o,
                             std::shared_ptr<ProblemData> pd)
        : op(std::move(o)), problemData(std::move(pd))
    {
    }
};

// Wrap SwapStar operator
struct SwapStarResource
{
    std::unique_ptr<search::SwapStar> op;
    std::shared_ptr<ProblemData> problemData;

    SwapStarResource(std::unique_ptr<search::SwapStar> o,
                     std::shared_ptr<ProblemData> pd)
        : op(std::move(o)), problemData(std::move(pd))
    {
    }
};

// Wrap SwapRoutes operator
struct SwapRoutesResource
{
    std::unique_ptr<search::SwapRoutes> op;
    std::shared_ptr<ProblemData> problemData;

    SwapRoutesResource(std::unique_ptr<search::SwapRoutes> o,
                       std::shared_ptr<ProblemData> pd)
        : op(std::move(o)), problemData(std::move(pd))
    {
    }
};

// Wrap SwapTails operator
struct SwapTailsResource
{
    std::unique_ptr<search::SwapTails> op;
    std::shared_ptr<ProblemData> problemData;

    SwapTailsResource(std::unique_ptr<search::SwapTails> o,
                      std::shared_ptr<ProblemData> pd)
        : op(std::move(o)), problemData(std::move(pd))
    {
    }
};

// Wrap RelocateWithDepot operator
struct RelocateWithDepotResource
{
    std::unique_ptr<search::RelocateWithDepot> op;
    std::shared_ptr<ProblemData> problemData;

    RelocateWithDepotResource(std::unique_ptr<search::RelocateWithDepot> o,
                              std::shared_ptr<ProblemData> pd)
        : op(std::move(o)), problemData(std::move(pd))
    {
    }
};

// Wrap RandomNumberGenerator for resource management
struct RNGResource
{
    RandomNumberGenerator rng;

    explicit RNGResource(uint32_t seed) : rng(seed) {}
    explicit RNGResource(std::array<uint32_t, 4> state) : rng(state) {}
};

// Wrap DynamicBitset for resource management
struct DynamicBitsetResource
{
    DynamicBitset bitset;

    explicit DynamicBitsetResource(size_t numBits) : bitset(numBits) {}
    explicit DynamicBitsetResource(DynamicBitset b) : bitset(std::move(b)) {}
};

// Wrap DurationSegment for resource management
struct DurationSegmentResource
{
    DurationSegment segment;

    DurationSegmentResource() : segment() {}
    explicit DurationSegmentResource(const DurationSegment &s) : segment(s) {}
};

// Wrap LoadSegment for resource management
struct LoadSegmentResource
{
    LoadSegment segment;

    LoadSegmentResource() : segment() {}
    explicit LoadSegmentResource(const LoadSegment &s) : segment(s) {}
};

// Wrap LocalSearch for resource management - allows reuse across iterations
struct LocalSearchResource
{
    std::shared_ptr<ProblemData> problemData;

    // Owned data
    search::PerturbationParams perturbParams;
    search::PerturbationManager perturbManager;
    search::SearchSpace::Neighbours neighbours;

    // Persistent RNG - reused across all calls like PyVRP does
    RandomNumberGenerator rng;

    // Owned operators (keep them alive)
    std::unique_ptr<search::Exchange<1, 0>> exchange10;
    std::unique_ptr<search::Exchange<2, 0>> exchange20;
    std::unique_ptr<search::Exchange<1, 1>> exchange11;
    std::unique_ptr<search::Exchange<2, 1>> exchange21;
    std::unique_ptr<search::Exchange<2, 2>> exchange22;
    std::unique_ptr<search::SwapTails> swapTails;
    std::unique_ptr<search::RelocateWithDepot> relocateDepot;
    std::unique_ptr<search::SwapRoutes> swapRoutes;

    // The local search object (must be last - uses references to above)
    std::unique_ptr<search::LocalSearch> ls;

    LocalSearchResource(std::shared_ptr<ProblemData> pd,
                        search::SearchSpace::Neighbours n,
                        uint32_t seed)
        : problemData(std::move(pd)),
          perturbParams(1, 25),
          perturbManager(perturbParams),
          neighbours(std::move(n)),
          rng(seed),
          exchange10(std::make_unique<search::Exchange<1, 0>>(*problemData)),
          exchange20(std::make_unique<search::Exchange<2, 0>>(*problemData)),
          exchange11(std::make_unique<search::Exchange<1, 1>>(*problemData)),
          exchange21(std::make_unique<search::Exchange<2, 1>>(*problemData)),
          exchange22(std::make_unique<search::Exchange<2, 2>>(*problemData))
    {
        auto &data = *problemData;

        // Create LocalSearch
        ls = std::make_unique<search::LocalSearch>(
            data, neighbours, perturbManager);

        // Add default operators matching PyVRP
        ls->addNodeOperator(*exchange10);
        ls->addNodeOperator(*exchange20);
        ls->addNodeOperator(*exchange11);
        ls->addNodeOperator(*exchange21);
        ls->addNodeOperator(*exchange22);

        if (search::supports<search::SwapTails>(data))
        {
            swapTails = std::make_unique<search::SwapTails>(data);
            ls->addNodeOperator(*swapTails);
        }

        if (search::supports<search::RelocateWithDepot>(data))
        {
            relocateDepot = std::make_unique<search::RelocateWithDepot>(data);
            ls->addNodeOperator(*relocateDepot);
        }

        // Add route operators for better exploration of solution space
        // SwapRoutes can help escape local optima in prize-collecting problems
        // by swapping visits between vehicles
        if (search::supports<search::SwapRoutes>(data))
        {
            swapRoutes = std::make_unique<search::SwapRoutes>(data);
            ls->addRouteOperator(*swapRoutes);
        }
    }
};

// Type aliases for templated operator resources (macros don't like angle
// brackets)
using Exchange10Resource = ExchangeOperatorResource<1, 0>;
using Exchange11Resource = ExchangeOperatorResource<1, 1>;
using Exchange20Resource = ExchangeOperatorResource<2, 0>;
using Exchange21Resource = ExchangeOperatorResource<2, 1>;
using Exchange22Resource = ExchangeOperatorResource<2, 2>;
using Exchange30Resource = ExchangeOperatorResource<3, 0>;
using Exchange31Resource = ExchangeOperatorResource<3, 1>;
using Exchange32Resource = ExchangeOperatorResource<3, 2>;
using Exchange33Resource = ExchangeOperatorResource<3, 3>;

FINE_RESOURCE(ProblemDataResource);
FINE_RESOURCE(SolutionResource);
FINE_RESOURCE(CostEvaluatorResource);
FINE_RESOURCE(SearchRouteResource);
FINE_RESOURCE(SearchNodeResource);
FINE_RESOURCE(Exchange10Resource);
FINE_RESOURCE(Exchange11Resource);
FINE_RESOURCE(Exchange20Resource);
FINE_RESOURCE(Exchange21Resource);
FINE_RESOURCE(Exchange22Resource);
FINE_RESOURCE(Exchange30Resource);
FINE_RESOURCE(Exchange31Resource);
FINE_RESOURCE(Exchange32Resource);
FINE_RESOURCE(Exchange33Resource);
FINE_RESOURCE(SwapStarResource);
FINE_RESOURCE(SwapRoutesResource);
FINE_RESOURCE(SwapTailsResource);
FINE_RESOURCE(RelocateWithDepotResource);
FINE_RESOURCE(RNGResource);
FINE_RESOURCE(DynamicBitsetResource);
FINE_RESOURCE(DurationSegmentResource);
FINE_RESOURCE(LoadSegmentResource);
FINE_RESOURCE(LocalSearchResource);

// -----------------------------------------------------------------------------
// Forward Declarations: Helper Functions
// -----------------------------------------------------------------------------

static bool get_number_as_double([[maybe_unused]] ErlNifEnv *env,
                                 ERL_NIF_TERM term,
                                 double *out);

static bool
prepare_node_transfer(fine::ResourcePtr<SearchRouteResource> &route_resource,
                      fine::ResourcePtr<SearchNodeResource> &node_resource);

static void
complete_node_transfer(fine::ResourcePtr<SearchRouteResource> &route_resource,
                       fine::ResourcePtr<SearchNodeResource> &node_resource,
                       bool transfer_from_old_route);

static void reconcile_route_ownership_impl(
    search::Route *route1,
    search::Route *route2,
    std::vector<std::unique_ptr<search::Route::Node>> &owned1,
    std::vector<std::unique_ptr<search::Route::Node>> &owned2);

static void reconcile_route_ownership(
    fine::ResourcePtr<SearchRouteResource> &route1_resource,
    fine::ResourcePtr<SearchRouteResource> &route2_resource);

static void
reconcile_route_ownership(std::shared_ptr<SearchRouteData> &route1_data,
                          std::shared_ptr<SearchRouteData> &route2_data);

// -----------------------------------------------------------------------------
// Helper: Decode Elixir structs to C++ types
// -----------------------------------------------------------------------------

// Decode a single client from Elixir map
ProblemData::Client decode_client([[maybe_unused]] ErlNifEnv *env,
                                  ERL_NIF_TERM term)
{
    int64_t x = 0, y = 0;
    std::vector<int64_t> delivery_vec, pickup_vec;
    int64_t service_duration = 0;
    int64_t tw_early = 0;
    int64_t tw_late = std::numeric_limits<int64_t>::max();
    int64_t release_time = 0;
    int64_t prize = 0;
    bool required = true;
    std::optional<size_t> group = std::nullopt;

    ERL_NIF_TERM key, value;
    ErlNifMapIterator iter;

    if (!enif_map_iterator_create(env, term, &iter, ERL_NIF_MAP_ITERATOR_FIRST))
    {
        throw std::runtime_error("Expected map for client");
    }

    while (enif_map_iterator_get_pair(env, &iter, &key, &value))
    {
        char atom_buf[256];
        if (enif_get_atom(env, key, atom_buf, sizeof(atom_buf), ERL_NIF_LATIN1))
        {
            std::string key_str(atom_buf);

            if (key_str == "x")
            {
                enif_get_int64(env, value, &x);
            }
            else if (key_str == "y")
            {
                enif_get_int64(env, value, &y);
            }
            else if (key_str == "delivery")
            {
                // Decode list of integers
                unsigned len;
                if (enif_get_list_length(env, value, &len))
                {
                    delivery_vec.resize(len);
                    ERL_NIF_TERM head, tail = value;
                    for (unsigned i = 0; i < len; i++)
                    {
                        enif_get_list_cell(env, tail, &head, &tail);
                        int64_t v;
                        enif_get_int64(env, head, &v);
                        delivery_vec[i] = v;
                    }
                }
            }
            else if (key_str == "pickup")
            {
                unsigned len;
                if (enif_get_list_length(env, value, &len))
                {
                    pickup_vec.resize(len);
                    ERL_NIF_TERM head, tail = value;
                    for (unsigned i = 0; i < len; i++)
                    {
                        enif_get_list_cell(env, tail, &head, &tail);
                        int64_t v;
                        enif_get_int64(env, head, &v);
                        pickup_vec[i] = v;
                    }
                }
            }
            else if (key_str == "service_duration")
            {
                enif_get_int64(env, value, &service_duration);
            }
            else if (key_str == "tw_early")
            {
                enif_get_int64(env, value, &tw_early);
            }
            else if (key_str == "tw_late")
            {
                // Check for :infinity atom
                char buf[32];
                if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1))
                {
                    if (std::string(buf) == "infinity")
                    {
                        tw_late = std::numeric_limits<int64_t>::max();
                    }
                }
                else
                {
                    enif_get_int64(env, value, &tw_late);
                }
            }
            else if (key_str == "release_time")
            {
                enif_get_int64(env, value, &release_time);
            }
            else if (key_str == "prize")
            {
                enif_get_int64(env, value, &prize);
            }
            else if (key_str == "required")
            {
                char buf[32];
                if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1))
                {
                    required = (std::string(buf) == "true");
                }
            }
            else if (key_str == "group")
            {
                // Check for nil
                char buf[32];
                if (!enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1)
                    || std::string(buf) != "nil")
                {
                    int64_t g;
                    if (enif_get_int64(env, value, &g))
                    {
                        group = static_cast<size_t>(g);
                    }
                }
            }
        }
        enif_map_iterator_next(env, &iter);
    }
    enif_map_iterator_destroy(env, &iter);

    // Convert multi-dimensional to single value (PyVRP uses vectors now)
    std::vector<Load> delivery_loads, pickup_loads;
    for (auto d : delivery_vec)
        delivery_loads.push_back(Load(d));
    for (auto p : pickup_vec)
        pickup_loads.push_back(Load(p));

    // If empty, use defaults
    if (delivery_loads.empty())
        delivery_loads.push_back(Load(0));
    if (pickup_loads.empty())
        pickup_loads.push_back(Load(0));

    return ProblemData::Client(Coordinate(x),
                               Coordinate(y),
                               std::move(delivery_loads),
                               std::move(pickup_loads),
                               Duration(service_duration),
                               Duration(tw_early),
                               Duration(tw_late),
                               Duration(release_time),
                               Cost(prize),
                               required,
                               group,
                               std::string("")  // name
    );
}

// Decode a single depot from Elixir map
ProblemData::Depot decode_depot([[maybe_unused]] ErlNifEnv *env,
                                ERL_NIF_TERM term)
{
    int64_t x = 0, y = 0;
    int64_t service_duration = 0;
    int64_t reload_cost = 0;

    ERL_NIF_TERM key, value;
    ErlNifMapIterator iter;

    if (!enif_map_iterator_create(env, term, &iter, ERL_NIF_MAP_ITERATOR_FIRST))
    {
        throw std::runtime_error("Expected map for depot");
    }

    while (enif_map_iterator_get_pair(env, &iter, &key, &value))
    {
        char atom_buf[256];
        if (enif_get_atom(env, key, atom_buf, sizeof(atom_buf), ERL_NIF_LATIN1))
        {
            std::string key_str(atom_buf);

            if (key_str == "x")
            {
                enif_get_int64(env, value, &x);
            }
            else if (key_str == "y")
            {
                enif_get_int64(env, value, &y);
            }
            else if (key_str == "service_duration")
            {
                enif_get_int64(env, value, &service_duration);
            }
            else if (key_str == "reload_cost")
            {
                enif_get_int64(env, value, &reload_cost);
            }
        }
        enif_map_iterator_next(env, &iter);
    }
    enif_map_iterator_destroy(env, &iter);

    return ProblemData::Depot(Coordinate(x),
                              Coordinate(y),
                              Duration(0),
                              std::numeric_limits<Duration>::max(),
                              Duration(service_duration),
                              Cost(reload_cost));
}

// Decode a single vehicle type from Elixir map
ProblemData::VehicleType decode_vehicle_type([[maybe_unused]] ErlNifEnv *env,
                                             ERL_NIF_TERM term,
                                             size_t num_dims)
{
    int64_t num_available = 1;
    std::vector<int64_t> capacity_vec;
    int64_t start_depot = 0;
    int64_t end_depot = 0;
    int64_t fixed_cost = 0;
    int64_t tw_early = 0;
    int64_t tw_late = std::numeric_limits<int64_t>::max();
    int64_t shift_duration = std::numeric_limits<int64_t>::max();
    int64_t max_distance = std::numeric_limits<int64_t>::max();
    int64_t unit_distance_cost = 1;
    int64_t unit_duration_cost = 0;
    int64_t profile = 0;
    int64_t max_overtime = 0;
    int64_t unit_overtime_cost = 0;
    std::vector<int64_t> reload_depots_vec;
    int64_t max_reloads = std::numeric_limits<int64_t>::max();
    std::vector<int64_t> initial_load_vec;
    std::string name;

    ERL_NIF_TERM key, value;
    ErlNifMapIterator iter;

    if (!enif_map_iterator_create(env, term, &iter, ERL_NIF_MAP_ITERATOR_FIRST))
    {
        throw std::runtime_error("Expected map for vehicle_type");
    }

    while (enif_map_iterator_get_pair(env, &iter, &key, &value))
    {
        char atom_buf[256];
        if (enif_get_atom(env, key, atom_buf, sizeof(atom_buf), ERL_NIF_LATIN1))
        {
            std::string key_str(atom_buf);

            if (key_str == "num_available")
            {
                enif_get_int64(env, value, &num_available);
            }
            else if (key_str == "capacity")
            {
                // Handle list or single value
                unsigned len;
                if (enif_get_list_length(env, value, &len))
                {
                    capacity_vec.resize(len);
                    ERL_NIF_TERM head, tail = value;
                    for (unsigned i = 0; i < len; i++)
                    {
                        enif_get_list_cell(env, tail, &head, &tail);
                        int64_t v;
                        enif_get_int64(env, head, &v);
                        capacity_vec[i] = v;
                    }
                }
            }
            else if (key_str == "start_depot")
            {
                enif_get_int64(env, value, &start_depot);
            }
            else if (key_str == "end_depot")
            {
                enif_get_int64(env, value, &end_depot);
            }
            else if (key_str == "fixed_cost")
            {
                enif_get_int64(env, value, &fixed_cost);
            }
            else if (key_str == "tw_early")
            {
                enif_get_int64(env, value, &tw_early);
            }
            else if (key_str == "tw_late")
            {
                char buf[32];
                if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1))
                {
                    if (std::string(buf) == "infinity")
                    {
                        tw_late = std::numeric_limits<int64_t>::max();
                    }
                }
                else
                {
                    enif_get_int64(env, value, &tw_late);
                }
            }
            else if (key_str == "shift_duration")
            {
                char buf[32];
                if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1))
                {
                    if (std::string(buf) == "infinity")
                    {
                        shift_duration = std::numeric_limits<int64_t>::max();
                    }
                }
                else
                {
                    enif_get_int64(env, value, &shift_duration);
                }
            }
            else if (key_str == "max_distance")
            {
                char buf[32];
                if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1))
                {
                    if (std::string(buf) == "infinity")
                    {
                        max_distance = std::numeric_limits<int64_t>::max();
                    }
                }
                else
                {
                    enif_get_int64(env, value, &max_distance);
                }
            }
            else if (key_str == "unit_distance_cost")
            {
                enif_get_int64(env, value, &unit_distance_cost);
            }
            else if (key_str == "unit_duration_cost")
            {
                enif_get_int64(env, value, &unit_duration_cost);
            }
            else if (key_str == "profile")
            {
                enif_get_int64(env, value, &profile);
            }
            else if (key_str == "max_overtime")
            {
                enif_get_int64(env, value, &max_overtime);
            }
            else if (key_str == "unit_overtime_cost")
            {
                enif_get_int64(env, value, &unit_overtime_cost);
            }
            else if (key_str == "reload_depots")
            {
                unsigned len;
                if (enif_get_list_length(env, value, &len))
                {
                    reload_depots_vec.resize(len);
                    ERL_NIF_TERM head, tail = value;
                    for (unsigned i = 0; i < len; i++)
                    {
                        enif_get_list_cell(env, tail, &head, &tail);
                        int64_t v;
                        enif_get_int64(env, head, &v);
                        reload_depots_vec[i] = v;
                    }
                }
            }
            else if (key_str == "max_reloads")
            {
                char buf[32];
                if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1))
                {
                    if (std::string(buf) == "infinity")
                    {
                        max_reloads = std::numeric_limits<int64_t>::max();
                    }
                }
                else
                {
                    enif_get_int64(env, value, &max_reloads);
                }
            }
            else if (key_str == "initial_load")
            {
                unsigned len;
                if (enif_get_list_length(env, value, &len))
                {
                    initial_load_vec.resize(len);
                    ERL_NIF_TERM head, tail = value;
                    for (unsigned i = 0; i < len; i++)
                    {
                        enif_get_list_cell(env, tail, &head, &tail);
                        int64_t v;
                        enif_get_int64(env, head, &v);
                        initial_load_vec[i] = v;
                    }
                }
            }
            else if (key_str == "name")
            {
                name = decode_binary_to_string(env, value);
            }
        }
        enif_map_iterator_next(env, &iter);
    }
    enif_map_iterator_destroy(env, &iter);

    // Convert capacity to vector<Load>
    std::vector<Load> capacity_loads;
    capacity_loads.reserve(std::max(capacity_vec.size(), num_dims));
    for (auto c : capacity_vec)
        capacity_loads.push_back(Load(c));

    // Ensure capacity has the right number of dimensions
    while (capacity_loads.size() < num_dims)
        capacity_loads.push_back(Load(0));

    // Convert initial_load to vector<Load>
    std::vector<Load> initial_loads;
    initial_loads.reserve(initial_load_vec.size());
    for (auto l : initial_load_vec)
        initial_loads.push_back(Load(l));

    // Convert reload_depots to vector<size_t>
    std::vector<size_t> reload_depots;
    reload_depots.reserve(reload_depots_vec.size());
    for (auto d : reload_depots_vec)
        reload_depots.push_back(static_cast<size_t>(d));

    return ProblemData::VehicleType(static_cast<size_t>(num_available),
                                    std::move(capacity_loads),
                                    static_cast<size_t>(start_depot),
                                    static_cast<size_t>(end_depot),
                                    Cost(fixed_cost),
                                    Duration(tw_early),
                                    Duration(tw_late),
                                    Duration(shift_duration),
                                    Distance(max_distance),
                                    Cost(unit_distance_cost),
                                    Cost(unit_duration_cost),
                                    static_cast<size_t>(profile),
                                    std::nullopt,  // startLate
                                    std::move(initial_loads),
                                    std::move(reload_depots),
                                    static_cast<size_t>(max_reloads),
                                    Duration(max_overtime),
                                    Cost(unit_overtime_cost),
                                    std::move(name));
}

// Decode distance/duration matrix from nested list
Matrix<Distance> decode_distance_matrix([[maybe_unused]] ErlNifEnv *env,
                                        ERL_NIF_TERM term)
{
    unsigned num_rows;
    if (!enif_get_list_length(env, term, &num_rows) || num_rows == 0)
    {
        return Matrix<Distance>();
    }

    // Get first row to determine columns
    ERL_NIF_TERM head, tail = term;
    enif_get_list_cell(env, tail, &head, &tail);

    unsigned num_cols;
    if (!enif_get_list_length(env, head, &num_cols) || num_cols == 0)
    {
        return Matrix<Distance>();
    }

    std::vector<Distance> data;
    data.reserve(static_cast<size_t>(num_rows) * num_cols);

    // Reset to beginning
    tail = term;
    for (unsigned r = 0; r < num_rows; r++)
    {
        enif_get_list_cell(env, tail, &head, &tail);

        ERL_NIF_TERM cell_head, cell_tail = head;
        for (unsigned c = 0; c < num_cols; c++)
        {
            enif_get_list_cell(env, cell_tail, &cell_head, &cell_tail);
            int64_t val;
            enif_get_int64(env, cell_head, &val);
            data.push_back(Distance(val));
        }
    }

    return Matrix<Distance>(std::move(data), num_rows, num_cols);
}

Matrix<Duration> decode_duration_matrix([[maybe_unused]] ErlNifEnv *env,
                                        ERL_NIF_TERM term)
{
    unsigned num_rows;
    if (!enif_get_list_length(env, term, &num_rows) || num_rows == 0)
    {
        return Matrix<Duration>();
    }

    ERL_NIF_TERM head, tail = term;
    enif_get_list_cell(env, tail, &head, &tail);

    unsigned num_cols;
    if (!enif_get_list_length(env, head, &num_cols) || num_cols == 0)
    {
        return Matrix<Duration>();
    }

    std::vector<Duration> data;
    data.reserve(static_cast<size_t>(num_rows) * num_cols);

    tail = term;
    for (unsigned r = 0; r < num_rows; r++)
    {
        enif_get_list_cell(env, tail, &head, &tail);

        ERL_NIF_TERM cell_head, cell_tail = head;
        for (unsigned c = 0; c < num_cols; c++)
        {
            enif_get_list_cell(env, cell_tail, &cell_head, &cell_tail);
            int64_t val;
            enif_get_int64(env, cell_head, &val);
            data.push_back(Duration(val));
        }
    }

    return Matrix<Duration>(std::move(data), num_rows, num_cols);
}

// Calculate Euclidean distance between two points
int64_t euclidean_distance(int64_t x1, int64_t y1, int64_t x2, int64_t y2)
{
    double dx = static_cast<double>(x2 - x1);
    double dy = static_cast<double>(y2 - y1);
    return static_cast<int64_t>(std::round(std::sqrt(dx * dx + dy * dy)));
}

// Decode Elixir binary to std::string
std::string decode_binary_to_string([[maybe_unused]] ErlNifEnv *env,
                                    ERL_NIF_TERM term)
{
    ErlNifBinary bin;
    if (enif_inspect_binary(env, term, &bin))
    {
        return std::string(reinterpret_cast<char *>(bin.data), bin.size);
    }
    // Try as iolist (which includes charlists)
    if (enif_inspect_iolist_as_binary(env, term, &bin))
    {
        return std::string(reinterpret_cast<char *>(bin.data), bin.size);
    }
    return "";
}

// Decode a ClientGroup from Elixir map
ProblemData::ClientGroup decode_client_group([[maybe_unused]] ErlNifEnv *env,
                                             ERL_NIF_TERM term)
{
    std::vector<size_t> clients;
    bool required = true;
    std::string name = "";

    ERL_NIF_TERM key, value;

    // Get clients list
    key = enif_make_atom(env, "clients");
    if (enif_get_map_value(env, term, key, &value))
    {
        unsigned len;
        if (enif_get_list_length(env, value, &len))
        {
            clients.reserve(len);
            ERL_NIF_TERM head, tail = value;
            for (unsigned i = 0; i < len; i++)
            {
                enif_get_list_cell(env, tail, &head, &tail);
                unsigned long client_idx;
                enif_get_ulong(env, head, &client_idx);
                clients.push_back(static_cast<size_t>(client_idx));
            }
        }
    }

    // Get required
    key = enif_make_atom(env, "required");
    if (enif_get_map_value(env, term, key, &value))
    {
        char atom_buf[16];
        if (enif_get_atom(
                env, value, atom_buf, sizeof(atom_buf), ERL_NIF_LATIN1))
        {
            required = (std::string(atom_buf) == "true");
        }
    }

    // Get name
    key = enif_make_atom(env, "name");
    if (enif_get_map_value(env, term, key, &value))
    {
        name = decode_binary_to_string(env, value);
    }

    return ProblemData::ClientGroup(clients, required, name);
}

// Decode a SameVehicleGroup from Elixir map
ProblemData::SameVehicleGroup
decode_same_vehicle_group([[maybe_unused]] ErlNifEnv *env, ERL_NIF_TERM term)
{
    std::vector<size_t> clients;
    std::string name = "";

    ERL_NIF_TERM key, value;

    // Get clients list
    key = enif_make_atom(env, "clients");
    if (enif_get_map_value(env, term, key, &value))
    {
        unsigned len;
        if (enif_get_list_length(env, value, &len))
        {
            clients.reserve(len);
            ERL_NIF_TERM head, tail = value;
            for (unsigned i = 0; i < len; i++)
            {
                enif_get_list_cell(env, tail, &head, &tail);
                unsigned long client_idx;
                enif_get_ulong(env, head, &client_idx);
                clients.push_back(static_cast<size_t>(client_idx));
            }
        }
    }

    // Get name
    key = enif_make_atom(env, "name");
    if (enif_get_map_value(env, term, key, &value))
    {
        name = decode_binary_to_string(env, value);
    }

    return ProblemData::SameVehicleGroup(clients, name);
}

// -----------------------------------------------------------------------------
// NIF Functions
// -----------------------------------------------------------------------------

/**
 * Create ProblemData from Elixir Model struct.
 */
fine::Ok<fine::ResourcePtr<ProblemDataResource>>
create_problem_data([[maybe_unused]] ErlNifEnv *env, fine::Term model_term)
{
    // Decode the model map
    ERL_NIF_TERM clients_term, depots_term, vehicle_types_term;
    ERL_NIF_TERM distance_matrices_term, duration_matrices_term;

    ERL_NIF_TERM key;

    // Get clients
    key = enif_make_atom(env, "clients");
    if (!enif_get_map_value(env, model_term, key, &clients_term))
    {
        throw std::runtime_error("Model missing clients field");
    }

    // Get depots
    key = enif_make_atom(env, "depots");
    if (!enif_get_map_value(env, model_term, key, &depots_term))
    {
        throw std::runtime_error("Model missing depots field");
    }

    // Get vehicle types
    key = enif_make_atom(env, "vehicle_types");
    if (!enif_get_map_value(env, model_term, key, &vehicle_types_term))
    {
        throw std::runtime_error("Model missing vehicle_types field");
    }

    // Get distance matrices (optional)
    key = enif_make_atom(env, "distance_matrices");
    bool has_dist_matrices
        = enif_get_map_value(env, model_term, key, &distance_matrices_term);

    // Get duration matrices (optional)
    key = enif_make_atom(env, "duration_matrices");
    bool has_dur_matrices
        = enif_get_map_value(env, model_term, key, &duration_matrices_term);

    // Get client groups (optional)
    ERL_NIF_TERM client_groups_term;
    key = enif_make_atom(env, "client_groups");
    bool has_client_groups
        = enif_get_map_value(env, model_term, key, &client_groups_term);

    // Get same vehicle groups (optional)
    ERL_NIF_TERM same_vehicle_groups_term;
    key = enif_make_atom(env, "same_vehicle_groups");
    bool has_same_vehicle_groups
        = enif_get_map_value(env, model_term, key, &same_vehicle_groups_term);

    // Decode depots
    std::vector<ProblemData::Depot> depots;
    unsigned depots_len;
    enif_get_list_length(env, depots_term, &depots_len);
    depots.reserve(depots_len);

    ERL_NIF_TERM head, tail = depots_term;
    for (unsigned i = 0; i < depots_len; i++)
    {
        enif_get_list_cell(env, tail, &head, &tail);
        depots.push_back(decode_depot(env, head));
    }

    // Decode clients
    std::vector<ProblemData::Client> clients;
    unsigned clients_len;
    enif_get_list_length(env, clients_term, &clients_len);
    clients.reserve(clients_len);

    size_t num_dims = 1;  // Default dimension count

    tail = clients_term;
    for (unsigned i = 0; i < clients_len; i++)
    {
        enif_get_list_cell(env, tail, &head, &tail);
        auto client = decode_client(env, head);
        if (i == 0)
        {
            // Use first client's delivery dimension count as reference
            // (PyVRP requires consistent dimensions)
        }
        clients.push_back(std::move(client));
    }

    if (!clients.empty())
    {
        num_dims = clients[0].delivery.size();
    }

    // Decode vehicle types
    std::vector<ProblemData::VehicleType> vehicle_types;
    unsigned vt_len;
    enif_get_list_length(env, vehicle_types_term, &vt_len);
    vehicle_types.reserve(vt_len);

    tail = vehicle_types_term;
    for (unsigned i = 0; i < vt_len; i++)
    {
        enif_get_list_cell(env, tail, &head, &tail);
        vehicle_types.push_back(decode_vehicle_type(env, head, num_dims));
    }

    // Create matrices
    size_t num_locations = depots.size() + clients.size();
    std::vector<Matrix<Distance>> dist_matrices;
    std::vector<Matrix<Duration>> dur_matrices;

    if (has_dist_matrices)
    {
        unsigned dm_len;
        enif_get_list_length(env, distance_matrices_term, &dm_len);
        if (dm_len > 0)
        {
            tail = distance_matrices_term;
            for (unsigned i = 0; i < dm_len; i++)
            {
                enif_get_list_cell(env, tail, &head, &tail);
                dist_matrices.push_back(decode_distance_matrix(env, head));
            }
        }
    }

    if (has_dur_matrices)
    {
        unsigned dm_len;
        enif_get_list_length(env, duration_matrices_term, &dm_len);
        if (dm_len > 0)
        {
            tail = duration_matrices_term;
            for (unsigned i = 0; i < dm_len; i++)
            {
                enif_get_list_cell(env, tail, &head, &tail);
                dur_matrices.push_back(decode_duration_matrix(env, head));
            }
        }
    }

    // If no matrices provided, generate from coordinates
    if (dist_matrices.empty())
    {
        Matrix<Distance> dist_mat(num_locations, num_locations);
        Matrix<Duration> dur_mat(num_locations, num_locations);

        // Helper to get coordinates
        auto get_coords = [&](size_t idx) -> std::pair<int64_t, int64_t>
        {
            if (idx < depots.size())
            {
                return {static_cast<int64_t>(depots[idx].x),
                        static_cast<int64_t>(depots[idx].y)};
            }
            else
            {
                auto &c = clients[idx - depots.size()];
                return {static_cast<int64_t>(c.x), static_cast<int64_t>(c.y)};
            }
        };

        for (size_t i = 0; i < num_locations; i++)
        {
            auto [x1, y1] = get_coords(i);
            for (size_t j = 0; j < num_locations; j++)
            {
                auto [x2, y2] = get_coords(j);
                int64_t dist = euclidean_distance(x1, y1, x2, y2);
                dist_mat(i, j) = Distance(dist);
                dur_mat(i, j) = Duration(dist);  // Assume unit speed
            }
        }

        dist_matrices.push_back(std::move(dist_mat));
        dur_matrices.push_back(std::move(dur_mat));
    }

    // Decode client groups
    std::vector<ProblemData::ClientGroup> client_groups;
    if (has_client_groups)
    {
        unsigned groups_len;
        if (enif_get_list_length(env, client_groups_term, &groups_len)
            && groups_len > 0)
        {
            client_groups.reserve(groups_len);
            tail = client_groups_term;
            for (unsigned i = 0; i < groups_len; i++)
            {
                enif_get_list_cell(env, tail, &head, &tail);
                client_groups.push_back(decode_client_group(env, head));
            }
        }
    }

    // Decode same vehicle groups
    std::vector<ProblemData::SameVehicleGroup> same_vehicle_groups;
    if (has_same_vehicle_groups)
    {
        unsigned groups_len;
        if (enif_get_list_length(env, same_vehicle_groups_term, &groups_len)
            && groups_len > 0)
        {
            same_vehicle_groups.reserve(groups_len);
            tail = same_vehicle_groups_term;
            for (unsigned i = 0; i < groups_len; i++)
            {
                enif_get_list_cell(env, tail, &head, &tail);
                same_vehicle_groups.push_back(
                    decode_same_vehicle_group(env, head));
            }
        }
    }

    // Create ProblemData
    auto problem_data
        = std::make_shared<ProblemData>(std::move(clients),
                                        std::move(depots),
                                        std::move(vehicle_types),
                                        std::move(dist_matrices),
                                        std::move(dur_matrices),
                                        std::move(client_groups),
                                        std::move(same_vehicle_groups));

    return fine::Ok(fine::make_resource<ProblemDataResource>(problem_data));
}

FINE_NIF(create_problem_data, 0);

/**
 * Get solution total distance.
 */
int64_t solution_distance([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<SolutionResource> solution_resource)
{
    return static_cast<int64_t>(solution_resource->solution.distance());
}

FINE_NIF(solution_distance, 0);

/**
 * Get solution total duration.
 */
int64_t solution_duration([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<SolutionResource> solution_resource)
{
    return static_cast<int64_t>(solution_resource->solution.duration());
}

FINE_NIF(solution_duration, 0);

/**
 * Check if solution is feasible.
 */
bool solution_is_feasible([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<SolutionResource> solution_resource)
{
    return solution_resource->solution.isFeasible();
}

FINE_NIF(solution_is_feasible, 0);

/**
 * Check if solution is group feasible (same-vehicle constraints satisfied).
 */
bool solution_is_group_feasible(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource)
{
    return solution_resource->solution.isGroupFeasible();
}

FINE_NIF(solution_is_group_feasible, 0);

/**
 * Check if solution is complete.
 */
bool solution_is_complete([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<SolutionResource> solution_resource)
{
    return solution_resource->solution.isComplete();
}

FINE_NIF(solution_is_complete, 0);

/**
 * Get number of routes in solution.
 */
int64_t
solution_num_routes([[maybe_unused]] ErlNifEnv *env,
                    fine::ResourcePtr<SolutionResource> solution_resource)
{
    return static_cast<int64_t>(solution_resource->solution.numRoutes());
}

FINE_NIF(solution_num_routes, 0);

/**
 * Get number of clients in solution.
 */
int64_t
solution_num_clients([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<SolutionResource> solution_resource)
{
    return static_cast<int64_t>(solution_resource->solution.numClients());
}

FINE_NIF(solution_num_clients, 0);

/**
 * Get routes from solution as list of client index lists.
 */
fine::Term
solution_routes([[maybe_unused]] ErlNifEnv *env,
                fine::ResourcePtr<SolutionResource> solution_resource)
{
    auto &solution = solution_resource->solution;

    auto const &routes = solution.routes();
    std::vector<ERL_NIF_TERM> route_terms;
    route_terms.reserve(routes.size());

    for (auto const &route : routes)
    {
        std::vector<ERL_NIF_TERM> client_terms;

        for (auto const &visit : route.visits())
        {
            // visits() returns client indices (already 0-based, relative to
            // clients)
            client_terms.push_back(
                enif_make_int64(env, static_cast<int64_t>(visit)));
        }

        route_terms.push_back(enif_make_list_from_array(
            env, client_terms.data(), client_terms.size()));
    }

    return fine::Term(
        enif_make_list_from_array(env, route_terms.data(), route_terms.size()));
}

FINE_NIF(solution_routes, 0);

/**
 * Get unassigned client indices from solution.
 */
fine::Term
solution_unassigned([[maybe_unused]] ErlNifEnv *env,
                    fine::ResourcePtr<SolutionResource> solution_resource)
{
    auto &solution = solution_resource->solution;
    auto const &neighbours = solution.neighbours();
    auto const numDepots = solution_resource->problemData->numDepots();

    std::vector<ERL_NIF_TERM> unassigned;

    // neighbours vector is indexed by location (depots first, then clients)
    // A None/nullopt entry means the location is unassigned
    // We only care about unassigned clients (indices >= numDepots)
    for (size_t i = numDepots; i < neighbours.size(); ++i)
    {
        if (!neighbours[i].has_value())
        {
            unassigned.push_back(enif_make_int64(env, static_cast<int64_t>(i)));
        }
    }

    return fine::Term(
        enif_make_list_from_array(env, unassigned.data(), unassigned.size()));
}

FINE_NIF(solution_unassigned, 0);

/**
 * Get distance of a specific route in the solution.
 */
int64_t
solution_route_distance([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<SolutionResource> solution_resource,
                        int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;  // Invalid index
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].distance());
}

FINE_NIF(solution_route_distance, 0);

/**
 * Get duration of a specific route in the solution.
 */
int64_t
solution_route_duration([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<SolutionResource> solution_resource,
                        int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].duration());
}

FINE_NIF(solution_route_duration, 0);

/**
 * Get delivery load of a specific route in the solution.
 */
fine::Term
solution_route_delivery([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<SolutionResource> solution_resource,
                        int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return fine::Term(enif_make_list(env, 0));
    }

    auto const &delivery = routes[static_cast<size_t>(route_idx)].delivery();
    std::vector<ERL_NIF_TERM> terms;
    terms.reserve(delivery.size());

    for (auto load : delivery)
    {
        terms.push_back(enif_make_int64(env, static_cast<int64_t>(load)));
    }

    return fine::Term(
        enif_make_list_from_array(env, terms.data(), terms.size()));
}

FINE_NIF(solution_route_delivery, 0);

/**
 * Get pickup load of a specific route in the solution.
 */
fine::Term
solution_route_pickup([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<SolutionResource> solution_resource,
                      int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return fine::Term(enif_make_list(env, 0));
    }

    auto const &pickup = routes[static_cast<size_t>(route_idx)].pickup();
    std::vector<ERL_NIF_TERM> terms;
    terms.reserve(pickup.size());

    for (auto load : pickup)
    {
        terms.push_back(enif_make_int64(env, static_cast<int64_t>(load)));
    }

    return fine::Term(
        enif_make_list_from_array(env, terms.data(), terms.size()));
}

FINE_NIF(solution_route_pickup, 0);

/**
 * Check if a specific route in the solution is feasible.
 */
bool solution_route_is_feasible(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return false;
    }

    return routes[static_cast<size_t>(route_idx)].isFeasible();
}

FINE_NIF(solution_route_is_feasible, 0);

/**
 * Get excess load of a specific route in the solution.
 */
fine::Term solution_route_excess_load(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return fine::Term(enif_make_list(env, 0));
    }

    auto const &excess = routes[static_cast<size_t>(route_idx)].excessLoad();
    std::vector<ERL_NIF_TERM> terms;
    terms.reserve(excess.size());

    for (auto load : excess)
    {
        terms.push_back(enif_make_int64(env, static_cast<int64_t>(load)));
    }

    return fine::Term(
        enif_make_list_from_array(env, terms.data(), terms.size()));
}

FINE_NIF(solution_route_excess_load, 0);

/**
 * Get time warp of a specific route in the solution.
 */
int64_t
solution_route_time_warp([[maybe_unused]] ErlNifEnv *env,
                         fine::ResourcePtr<SolutionResource> solution_resource,
                         int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].timeWarp());
}

FINE_NIF(solution_route_time_warp, 0);

/**
 * Get excess distance of a specific route in the solution.
 */
int64_t solution_route_excess_distance(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].excessDistance());
}

FINE_NIF(solution_route_excess_distance, 0);

/**
 * Get overtime of a specific route in the solution.
 */
int64_t
solution_route_overtime([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<SolutionResource> solution_resource,
                        int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].overtime());
}

FINE_NIF(solution_route_overtime, 0);

/**
 * Check if a specific route has excess load.
 */
bool solution_route_has_excess_load(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return false;
    }

    return routes[static_cast<size_t>(route_idx)].hasExcessLoad();
}

FINE_NIF(solution_route_has_excess_load, 0);

/**
 * Check if a specific route has time warp.
 */
bool solution_route_has_time_warp(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return false;
    }

    return routes[static_cast<size_t>(route_idx)].hasTimeWarp();
}

FINE_NIF(solution_route_has_time_warp, 0);

/**
 * Check if a specific route has excess distance.
 */
bool solution_route_has_excess_distance(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return false;
    }

    return routes[static_cast<size_t>(route_idx)].hasExcessDistance();
}

FINE_NIF(solution_route_has_excess_distance, 0);

/**
 * Get vehicle type of a specific route.
 */
int64_t solution_route_vehicle_type(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return -1;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].vehicleType());
}

FINE_NIF(solution_route_vehicle_type, 0);

/**
 * Get start depot of a specific route.
 */
int64_t solution_route_start_depot(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return -1;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].startDepot());
}

FINE_NIF(solution_route_start_depot, 0);

/**
 * Get end depot of a specific route.
 */
int64_t
solution_route_end_depot([[maybe_unused]] ErlNifEnv *env,
                         fine::ResourcePtr<SolutionResource> solution_resource,
                         int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return -1;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].endDepot());
}

FINE_NIF(solution_route_end_depot, 0);

/**
 * Get number of trips in a specific route.
 */
int64_t
solution_route_num_trips([[maybe_unused]] ErlNifEnv *env,
                         fine::ResourcePtr<SolutionResource> solution_resource,
                         int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].numTrips());
}

FINE_NIF(solution_route_num_trips, 0);

/**
 * Get centroid of a specific route.
 */
fine::Term
solution_route_centroid([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<SolutionResource> solution_resource,
                        int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return fine::Term(enif_make_tuple2(
            env, enif_make_double(env, 0.0), enif_make_double(env, 0.0)));
    }

    auto const &centroid = routes[static_cast<size_t>(route_idx)].centroid();
    return fine::Term(enif_make_tuple2(
        env,
        enif_make_double(env, static_cast<double>(centroid.first)),
        enif_make_double(env, static_cast<double>(centroid.second))));
}

FINE_NIF(solution_route_centroid, 0);

/**
 * Get start time of a specific route.
 */
int64_t
solution_route_start_time([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<SolutionResource> solution_resource,
                          int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].startTime());
}

FINE_NIF(solution_route_start_time, 0);

/**
 * Get end time of a specific route.
 */
int64_t
solution_route_end_time([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<SolutionResource> solution_resource,
                        int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].endTime());
}

FINE_NIF(solution_route_end_time, 0);

/**
 * Get slack of a specific route.
 */
int64_t
solution_route_slack([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<SolutionResource> solution_resource,
                     int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(routes[static_cast<size_t>(route_idx)].slack());
}

FINE_NIF(solution_route_slack, 0);

/**
 * Get service duration of a specific route.
 */
int64_t solution_route_service_duration(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].serviceDuration());
}

FINE_NIF(solution_route_service_duration, 0);

/**
 * Get travel duration of a specific route.
 */
int64_t solution_route_travel_duration(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].travelDuration());
}

FINE_NIF(solution_route_travel_duration, 0);

/**
 * Get wait duration of a specific route.
 */
int64_t solution_route_wait_duration(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].waitDuration());
}

FINE_NIF(solution_route_wait_duration, 0);

/**
 * Get distance cost of a specific route.
 */
int64_t solution_route_distance_cost(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].distanceCost());
}

FINE_NIF(solution_route_distance_cost, 0);

/**
 * Get duration cost of a specific route.
 */
int64_t solution_route_duration_cost(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].durationCost());
}

FINE_NIF(solution_route_duration_cost, 0);

/**
 * Get reload cost of a specific route.
 */
int64_t solution_route_reload_cost(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].reloadCost());
}

FINE_NIF(solution_route_reload_cost, 0);

/**
 * Get prizes collected on a specific route.
 */
int64_t
solution_route_prizes([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<SolutionResource> solution_resource,
                      int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return 0;
    }

    return static_cast<int64_t>(
        routes[static_cast<size_t>(route_idx)].prizes());
}

FINE_NIF(solution_route_prizes, 0);

/**
 * Get visits of a specific route (client indices).
 */
fine::Term
solution_route_visits([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<SolutionResource> solution_resource,
                      int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return fine::Term(enif_make_list(env, 0));
    }

    auto const &visits = routes[static_cast<size_t>(route_idx)].visits();
    std::vector<ERL_NIF_TERM> terms;
    terms.reserve(visits.size());

    for (auto client : visits)
    {
        terms.push_back(enif_make_int64(env, static_cast<int64_t>(client)));
    }

    return fine::Term(
        enif_make_list_from_array(env, terms.data(), terms.size()));
}

FINE_NIF(solution_route_visits, 0);

/**
 * Get the schedule of a route (list of ScheduledVisit).
 * Returns a list of tuples: {location, trip, start_service, end_service,
 * wait_duration, time_warp}
 */
fine::Term
solution_route_schedule([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<SolutionResource> solution_resource,
                        int64_t route_idx)
{
    auto &solution = solution_resource->solution;
    auto const &routes = solution.routes();

    if (route_idx < 0 || static_cast<size_t>(route_idx) >= routes.size())
    {
        return fine::Term(enif_make_list(env, 0));
    }

    auto const &schedule = routes[static_cast<size_t>(route_idx)].schedule();
    std::vector<ERL_NIF_TERM> terms;
    terms.reserve(schedule.size());

    for (auto const &visit : schedule)
    {
        // Create a tuple: {location, trip, start_service, end_service,
        // wait_duration, time_warp}
        ERL_NIF_TERM tuple = enif_make_tuple6(
            env,
            enif_make_int64(env, static_cast<int64_t>(visit.location)),
            enif_make_int64(env, static_cast<int64_t>(visit.trip)),
            enif_make_int64(env, static_cast<int64_t>(visit.startService)),
            enif_make_int64(env, static_cast<int64_t>(visit.endService)),
            enif_make_int64(env, static_cast<int64_t>(visit.waitDuration)),
            enif_make_int64(env, static_cast<int64_t>(visit.timeWarp)));
        terms.push_back(tuple);
    }

    return fine::Term(
        enif_make_list_from_array(env, terms.data(), terms.size()));
}

FINE_NIF(solution_route_schedule, 0);

/**
 * Get the total fixed vehicle cost of the solution.
 */
int64_t solution_fixed_vehicle_cost(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource)
{
    auto &solution = solution_resource->solution;
    return static_cast<int64_t>(solution.fixedVehicleCost());
}

FINE_NIF(solution_fixed_vehicle_cost, 0);

// -----------------------------------------------------------------------------
// CostEvaluator
// -----------------------------------------------------------------------------

/**
 * Create a CostEvaluator from options (map).
 */
fine::Ok<fine::ResourcePtr<CostEvaluatorResource>>
create_cost_evaluator_nif([[maybe_unused]] ErlNifEnv *env, fine::Term opts_term)
{
    std::vector<double> load_penalties;
    double tw_penalty = 1.0;
    double dist_penalty = 1.0;

    ERL_NIF_TERM key, value;

    // Get load_penalties
    key = enif_make_atom(env, "load_penalties");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        unsigned len;
        if (enif_get_list_length(env, value, &len))
        {
            load_penalties.reserve(len);
            ERL_NIF_TERM head, tail = value;
            for (unsigned i = 0; i < len; i++)
            {
                enif_get_list_cell(env, tail, &head, &tail);
                double v = 0.0;
                if (!get_number_as_double(env, head, &v))
                {
                    throw std::runtime_error(
                        "load_penalties must be a list of numbers");
                }
                load_penalties.push_back(v);
            }
        }
    }

    // Get tw_penalty
    key = enif_make_atom(env, "tw_penalty");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        if (!get_number_as_double(env, value, &tw_penalty))
        {
            throw std::runtime_error("tw_penalty must be a number");
        }
    }

    // Get dist_penalty
    key = enif_make_atom(env, "dist_penalty");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        if (!get_number_as_double(env, value, &dist_penalty))
        {
            throw std::runtime_error("dist_penalty must be a number");
        }
    }

    // Validate: penalties must be non-negative
    for (auto p : load_penalties)
    {
        if (p < 0)
        {
            throw std::runtime_error("Load penalties must be non-negative");
        }
    }
    if (tw_penalty < 0 || dist_penalty < 0)
    {
        throw std::runtime_error("Penalties must be non-negative");
    }

    return fine::Ok(fine::make_resource<CostEvaluatorResource>(
        std::move(load_penalties), tw_penalty, dist_penalty));
}

FINE_NIF(create_cost_evaluator_nif, 0);

/**
 * Compute penalised cost of solution.
 */
int64_t solution_penalised_cost(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(evaluator_resource->evaluator.penalisedCost(
        solution_resource->solution));
}

FINE_NIF(solution_penalised_cost, 0);

/**
 * Compute cost of solution (max for infeasible).
 */
fine::Term
solution_cost([[maybe_unused]] ErlNifEnv *env,
              fine::ResourcePtr<SolutionResource> solution_resource,
              fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    auto cost = evaluator_resource->evaluator.cost(solution_resource->solution);
    if (cost == std::numeric_limits<Cost>::max())
    {
        return fine::Term(enif_make_atom(env, "infinity"));
    }
    return fine::Term(enif_make_int64(env, static_cast<int64_t>(cost)));
}

FINE_NIF(solution_cost, 0);

// -----------------------------------------------------------------------------
// Random Solution
// -----------------------------------------------------------------------------

/**
 * Create a random solution.
 */
fine::Ok<fine::ResourcePtr<SolutionResource>> create_random_solution_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource,
    fine::Term opts_term)
{
    auto &problem_data = problem_resource->data;

    // Parse options
    int64_t seed = 42;

    ERL_NIF_TERM key, value;
    key = enif_make_atom(env, "seed");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        enif_get_int64(env, value, &seed);
    }

    // Create RNG
    RandomNumberGenerator rng(static_cast<uint32_t>(seed));

    // Create random solution
    Solution solution(*problem_data, rng);

    return fine::Ok(fine::make_resource<SolutionResource>(std::move(solution),
                                                          problem_data));
}

FINE_NIF(create_random_solution_nif, 0);

/**
 * Create a solution from explicit routes.
 * Routes is a list of lists of client IDs (size_t values).
 */
fine::Ok<fine::ResourcePtr<SolutionResource>> create_solution_from_routes_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource,
    fine::Term routes_term)
{
    auto &problem_data = problem_resource->data;

    // Parse routes: list of lists of integers
    std::vector<std::vector<size_t>> routes;

    unsigned num_routes;
    if (!enif_get_list_length(env, routes_term, &num_routes))
    {
        throw std::runtime_error("Expected list for routes");
    }

    routes.reserve(num_routes);

    ERL_NIF_TERM route_head, route_tail = routes_term;
    for (unsigned i = 0; i < num_routes; i++)
    {
        if (!enif_get_list_cell(env, route_tail, &route_head, &route_tail))
        {
            throw std::runtime_error("Failed to get route from list");
        }

        // Each route is a list of client IDs
        std::vector<size_t> route;
        unsigned route_len;
        if (!enif_get_list_length(env, route_head, &route_len))
        {
            throw std::runtime_error("Expected list for route");
        }

        route.reserve(route_len);

        ERL_NIF_TERM client_head, client_tail = route_head;
        for (unsigned j = 0; j < route_len; j++)
        {
            if (!enif_get_list_cell(
                    env, client_tail, &client_head, &client_tail))
            {
                throw std::runtime_error("Failed to get client from route");
            }

            int64_t client_id;
            if (!enif_get_int64(env, client_head, &client_id))
            {
                throw std::runtime_error("Expected integer for client ID");
            }
            route.push_back(static_cast<size_t>(client_id));
        }

        routes.push_back(std::move(route));
    }

    // Create solution from routes
    Solution solution(*problem_data, routes);

    return fine::Ok(fine::make_resource<SolutionResource>(std::move(solution),
                                                          problem_data));
}

FINE_NIF(create_solution_from_routes_nif, 0);

/**
 * Get the number of load dimensions from ProblemData.
 */
int64_t problem_data_num_load_dims(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    return static_cast<int64_t>(problem_resource->data->numLoadDimensions());
}

FINE_NIF(problem_data_num_load_dims, 0);

/**
 * Get the number of clients from ProblemData.
 */
int64_t problem_data_num_clients(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    return static_cast<int64_t>(problem_resource->data->numClients());
}

FINE_NIF(problem_data_num_clients, 0);

/**
 * Get the number of depots from ProblemData.
 */
int64_t
problem_data_num_depots([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    return static_cast<int64_t>(problem_resource->data->numDepots());
}

FINE_NIF(problem_data_num_depots, 0);

/**
 * Get the total number of locations (depots + clients) from ProblemData.
 */
int64_t problem_data_num_locations(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    return static_cast<int64_t>(problem_resource->data->numLocations());
}

FINE_NIF(problem_data_num_locations, 0);

/**
 * Get the number of vehicle types from ProblemData.
 */
int64_t problem_data_num_vehicle_types(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    return static_cast<int64_t>(problem_resource->data->numVehicleTypes());
}

FINE_NIF(problem_data_num_vehicle_types, 0);

/**
 * Get the total number of vehicles from ProblemData.
 */
int64_t problem_data_num_vehicles(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    return static_cast<int64_t>(problem_resource->data->numVehicles());
}

FINE_NIF(problem_data_num_vehicles, 0);

// Check if problem data has time windows
bool problem_data_has_time_windows_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    return problem_resource->data->hasTimeWindows();
}

FINE_NIF(problem_data_has_time_windows_nif, 0);

// Get centroid of all client locations
std::tuple<double, double> problem_data_centroid_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto const &centroid = problem_resource->data->centroid();
    return std::make_tuple(static_cast<double>(centroid.first),
                           static_cast<double>(centroid.second));
}

FINE_NIF(problem_data_centroid_nif, 0);

// Get number of profiles (distance/duration matrices)
int64_t problem_data_num_profiles_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    return static_cast<int64_t>(problem_resource->data->numProfiles());
}

FINE_NIF(problem_data_num_profiles_nif, 0);

// -----------------------------------------------------------------------------
// ProblemData - Data Extraction for Neighbourhood Computation
// -----------------------------------------------------------------------------

/**
 * Get all client data needed for neighbourhood computation.
 * Returns: [{tw_early, tw_late, service_duration, prize}, ...]
 */
std::vector<std::tuple<int64_t, int64_t, int64_t, int64_t>>
problem_data_clients_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto const &clients = problem_resource->data->clients();
    std::vector<std::tuple<int64_t, int64_t, int64_t, int64_t>> result;
    result.reserve(clients.size());

    for (auto const &client : clients)
    {
        result.emplace_back(static_cast<int64_t>(client.twEarly),
                            static_cast<int64_t>(client.twLate),
                            static_cast<int64_t>(client.serviceDuration),
                            static_cast<int64_t>(client.prize));
    }

    return result;
}

FINE_NIF(problem_data_clients_nif, 0);

/**
 * Get distance matrix for a specific profile.
 * Returns nested list [[int, ...], ...]
 */
std::vector<std::vector<int64_t>> problem_data_distance_matrix_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource,
    int64_t profile)
{
    auto const &matrix
        = problem_resource->data->distanceMatrix(static_cast<size_t>(profile));
    size_t n = problem_resource->data->numLocations();

    std::vector<std::vector<int64_t>> result(n);
    for (size_t i = 0; i < n; ++i)
    {
        result[i].reserve(n);
        for (size_t j = 0; j < n; ++j)
        {
            result[i].push_back(static_cast<int64_t>(matrix(i, j)));
        }
    }

    return result;
}

FINE_NIF(problem_data_distance_matrix_nif, 0);

/**
 * Get duration matrix for a specific profile.
 * Returns nested list [[int, ...], ...]
 */
std::vector<std::vector<int64_t>> problem_data_duration_matrix_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource,
    int64_t profile)
{
    auto const &matrix
        = problem_resource->data->durationMatrix(static_cast<size_t>(profile));
    size_t n = problem_resource->data->numLocations();

    std::vector<std::vector<int64_t>> result(n);
    for (size_t i = 0; i < n; ++i)
    {
        result[i].reserve(n);
        for (size_t j = 0; j < n; ++j)
        {
            result[i].push_back(static_cast<int64_t>(matrix(i, j)));
        }
    }

    return result;
}

FINE_NIF(problem_data_duration_matrix_nif, 0);

/**
 * Get vehicle type cost info for neighbourhood computation.
 * Returns: [{unit_distance_cost, unit_duration_cost, profile}, ...]
 */
std::vector<std::tuple<int64_t, int64_t, int64_t>>
problem_data_vehicle_types_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto const &vehicleTypes = problem_resource->data->vehicleTypes();
    std::vector<std::tuple<int64_t, int64_t, int64_t>> result;
    result.reserve(vehicleTypes.size());

    for (auto const &vt : vehicleTypes)
    {
        result.emplace_back(static_cast<int64_t>(vt.unitDistanceCost),
                            static_cast<int64_t>(vt.unitDurationCost),
                            static_cast<int64_t>(vt.profile));
    }

    return result;
}

FINE_NIF(problem_data_vehicle_types_nif, 0);

/**
 * Get client groups for neighbourhood computation.
 * Returns: [{[client_indices], mutually_exclusive}, ...]
 */
std::vector<std::tuple<std::vector<int64_t>, bool>>
problem_data_groups_nif([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto const &groups = problem_resource->data->groups();
    std::vector<std::tuple<std::vector<int64_t>, bool>> result;
    result.reserve(groups.size());

    for (auto const &group : groups)
    {
        std::vector<int64_t> clients;
        clients.reserve(group.clients().size());
        for (auto client : group.clients())
        {
            // Client indices in groups are 0-indexed relative to clients,
            // but we need location indices (offset by num_depots)
            clients.push_back(static_cast<int64_t>(
                client + problem_resource->data->numDepots()));
        }
        result.emplace_back(std::move(clients), group.mutuallyExclusive);
    }

    return result;
}

FINE_NIF(problem_data_groups_nif, 0);

// -----------------------------------------------------------------------------
// LocalSearch
// -----------------------------------------------------------------------------

/**
 * Compute proximity-based neighbours matching PyVRP's compute_neighbours.
 *
 * Proximity is based on Vidal et al. (2013) hybrid genetic algorithm paper.
 * This considers edge costs, time window penalties, and prizes.
 */
pyvrp::search::SearchSpace::Neighbours
build_neighbours(ProblemData const &data,
                 size_t numNeighbours = 60,
                 double weightWaitTime = 0.2,
                 double weightTimeWarp = 1.0,
                 bool symmetricProximity = true)
{
    size_t const numLocs = data.numLocations();
    size_t const numDepots = data.numDepots();
    size_t const numClients = data.numClients();
    pyvrp::search::SearchSpace::Neighbours neighbours(numLocs);

    // Step 1: Collect unique (unitDistCost, unitDurCost, profile) combinations
    std::set<std::tuple<Cost, Cost, size_t>> uniqueEdgeCosts;
    for (auto const &vt : data.vehicleTypes())
    {
        uniqueEdgeCosts.insert(
            {vt.unitDistanceCost, vt.unitDurationCost, vt.profile});
    }

    // Step 2: Compute minimum edge cost matrix across all vehicle types
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

    // Step 3: Compute minimum duration matrix across all profiles (store as
    // double)
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

    // Step 4: Extract client time windows and service durations (store as
    // double) Clients start at index numDepots in location array
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

    // Step 5: Add time window penalties and subtract prizes
    // min_wait[i][j] = early[j] - minDuration[i][j] - service[i] - late[i]
    // min_tw[i][j] = early[i] + service[i] + minDuration[i][j] - late[j]
    for (size_t i = 0; i < numLocs; ++i)
    {
        for (size_t j = 0; j < numLocs; ++j)
        {
            // Subtract prize for visiting j
            edgeCosts[i][j] -= prize[j];

            // Wait time penalty (arriving too early at j)
            double minWait
                = early[j] - minDuration[i][j] - service[i] - late[i];
            if (minWait > 0)
            {
                edgeCosts[i][j] += weightWaitTime * minWait;
            }

            // Time warp penalty (arriving too late at j)
            double minTw = early[i] + service[i] + minDuration[i][j] - late[j];
            if (minTw > 0)
            {
                edgeCosts[i][j] += weightTimeWarp * minTw;
            }
        }
    }

    // Step 6: Symmetrize proximity if requested
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

    // Step 7: Handle mutually exclusive groups - high proximity for same-group
    // clients
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
                        // Use max double (not infinity) to order before depots
                        edgeCosts[ci][cj] = std::numeric_limits<double>::max();
                    }
                }
            }
        }
    }

    // Step 8: Set diagonal and depot entries to infinity
    for (size_t i = 0; i < numLocs; ++i)
    {
        edgeCosts[i][i] = std::numeric_limits<double>::infinity();  // Self
    }
    for (size_t d = 0; d < numDepots; ++d)
    {
        for (size_t j = 0; j < numLocs; ++j)
        {
            edgeCosts[d][j]
                = std::numeric_limits<double>::infinity();  // Depots have no
                                                            // neighbours
            edgeCosts[j][d]
                = std::numeric_limits<double>::infinity();  // Clients don't
                                                            // neighbour depots
        }
    }

    // Step 9: For each client, find k nearest by proximity
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

        // Partial sort: only sort the first k elements - O(n log k) instead of
        // O(n log n)
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

/**
 * Perform local search on a solution.
 */
fine::Ok<fine::ResourcePtr<SolutionResource>>
local_search_nif([[maybe_unused]] ErlNifEnv *env,
                 fine::ResourcePtr<SolutionResource> solution_resource,
                 fine::ResourcePtr<ProblemDataResource> problem_resource,
                 fine::ResourcePtr<CostEvaluatorResource> evaluator_resource,
                 fine::Term opts_term)
{
    auto &problem_data = *problem_resource->data;
    auto &cost_evaluator = evaluator_resource->evaluator;

    // Parse options
    bool exhaustive = false;
    int64_t seed = 42;

    ERL_NIF_TERM key, value;
    key = enif_make_atom(env, "exhaustive");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        char buf[32];
        if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1))
        {
            exhaustive = (std::string(buf) == "true");
        }
    }
    key = enif_make_atom(env, "seed");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        enif_get_int64(env, value, &seed);
    }

    // Build neighbourhood
    auto neighbours = build_neighbours(problem_data);

    // Create perturbation manager with default params
    pyvrp::search::PerturbationParams perturbParams(1, 25);
    pyvrp::search::PerturbationManager perturbManager(perturbParams);

    // Create local search
    pyvrp::search::LocalSearch ls(problem_data, neighbours, perturbManager);

    // Add node operators - matching PyVRP's default NODE_OPERATORS
    pyvrp::search::Exchange<1, 0> relocate(problem_data);   // RELOCATE
    pyvrp::search::Exchange<2, 0> relocate2(problem_data);  // 2-RELOCATE
    pyvrp::search::Exchange<1, 1> swap11(problem_data);     // SWAP(1,1)
    pyvrp::search::Exchange<2, 1> swap21(problem_data);     // SWAP(2,1)
    pyvrp::search::Exchange<2, 2> swap22(problem_data);     // SWAP(2,2)
    pyvrp::search::SwapTails swapTails(problem_data);       // SWAP-TAILS

    ls.addNodeOperator(relocate);
    ls.addNodeOperator(relocate2);
    ls.addNodeOperator(swap11);
    ls.addNodeOperator(swap21);
    ls.addNodeOperator(swap22);
    if (pyvrp::search::supports<pyvrp::search::SwapTails>(problem_data))
    {
        ls.addNodeOperator(swapTails);
    }

    // RelocateWithDepot only if supported (needs reload depots)
    std::unique_ptr<pyvrp::search::RelocateWithDepot> relocateDepot;
    if (pyvrp::search::supports<pyvrp::search::RelocateWithDepot>(problem_data))
    {
        relocateDepot
            = std::make_unique<pyvrp::search::RelocateWithDepot>(problem_data);
        ls.addNodeOperator(*relocateDepot);
    }

    // Note: PyVRP's default ROUTE_OPERATORS is empty

    // Create RNG and shuffle (like Python's __call__ does)
    RandomNumberGenerator rng(static_cast<uint32_t>(seed));
    ls.shuffle(rng);

    // Run local search (operator() = perturbation + search + intensify loop)
    Solution improved
        = ls(solution_resource->solution, cost_evaluator, exhaustive);

    return fine::Ok(fine::make_resource<SolutionResource>(
        std::move(improved), problem_resource->data));
}

FINE_NIF(local_search_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND);

/**
 * Perform search-only local search (no perturbation).
 *
 * This matches PyVRP's ls.search() method which is used for the initial
 * solution. Unlike local_search_nif (which calls operator() with perturbation),
 * this calls the search() method directly after shuffling.
 *
 * PyVRP: init = ls.search(Solution(data, []), pm.max_cost_evaluator())
 */
fine::Ok<fine::ResourcePtr<SolutionResource>> local_search_search_only_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    fine::ResourcePtr<ProblemDataResource> problem_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource,
    fine::Term opts_term)
{
    auto &problem_data = *problem_resource->data;
    auto &cost_evaluator = evaluator_resource->evaluator;

    // Parse options
    int64_t seed = 42;

    ERL_NIF_TERM key, value;
    key = enif_make_atom(env, "seed");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        enif_get_int64(env, value, &seed);
    }

    // Build neighbourhood
    auto neighbours = build_neighbours(problem_data);

    // Create perturbation manager (won't be used but required for LocalSearch
    // constructor)
    pyvrp::search::PerturbationParams perturbParams(1, 25);
    pyvrp::search::PerturbationManager perturbManager(perturbParams);

    // Create local search
    pyvrp::search::LocalSearch ls(problem_data, neighbours, perturbManager);

    // Add node operators - matching PyVRP's default NODE_OPERATORS:
    // Exchange10, Exchange20, Exchange11, Exchange21, Exchange22, SwapTails,
    // RelocateWithDepot Note: PyVRP's default ROUTE_OPERATORS is empty, so we
    // don't add SwapStar/SwapRoutes here
    pyvrp::search::Exchange<1, 0> relocate(problem_data);   // RELOCATE
    pyvrp::search::Exchange<2, 0> relocate2(problem_data);  // 2-RELOCATE
    pyvrp::search::Exchange<1, 1> swap11(problem_data);     // SWAP(1,1)
    pyvrp::search::Exchange<2, 1> swap21(problem_data);     // SWAP(2,1)
    pyvrp::search::Exchange<2, 2> swap22(problem_data);     // SWAP(2,2)
    pyvrp::search::SwapTails swapTails(problem_data);       // SWAP-TAILS

    ls.addNodeOperator(relocate);
    ls.addNodeOperator(relocate2);
    ls.addNodeOperator(swap11);
    ls.addNodeOperator(swap21);
    ls.addNodeOperator(swap22);
    // SwapTails.supports() returns true if numVehicles > 1
    if (pyvrp::search::supports<pyvrp::search::SwapTails>(problem_data))
    {
        ls.addNodeOperator(swapTails);
    }

    // RelocateWithDepot only if supported (needs reload depots)
    std::unique_ptr<pyvrp::search::RelocateWithDepot> relocateDepot;
    if (pyvrp::search::supports<pyvrp::search::RelocateWithDepot>(problem_data))
    {
        relocateDepot
            = std::make_unique<pyvrp::search::RelocateWithDepot>(problem_data);
        ls.addNodeOperator(*relocateDepot);
    }

    // Note: PyVRP's default ROUTE_OPERATORS is empty - don't add
    // SwapStar/SwapRoutes

    // Create RNG and shuffle (like Python's ls.search() does)
    RandomNumberGenerator rng(static_cast<uint32_t>(seed));
    ls.shuffle(rng);

    // Run search-only (no perturbation) - this is what PyVRP uses for initial
    // solution
    Solution improved = ls.search(solution_resource->solution, cost_evaluator);

    return fine::Ok(fine::make_resource<SolutionResource>(
        std::move(improved), problem_resource->data));
}

FINE_NIF(local_search_search_only_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// -----------------------------------------------------------------------------
// Configurable Local Search - allows specifying which operators to use
// -----------------------------------------------------------------------------

/**
 * Perform local search with specific operators.
 *
 * Options:
 * - :node_operators - list of atom operator names: [:exchange10, :exchange11,
 * ...]
 * - :route_operators - list of atom operator names: [:swap_star, :swap_routes]
 * - :exhaustive - boolean (default false)
 */
fine::Ok<fine::ResourcePtr<SolutionResource>> local_search_with_operators_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    fine::ResourcePtr<ProblemDataResource> problem_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource,
    fine::Term opts_term)
{
    auto &problem_data = *problem_resource->data;
    auto &cost_evaluator = evaluator_resource->evaluator;

    // Parse options
    bool exhaustive = false;
    int64_t seed = 42;
    std::vector<std::string> node_ops;
    std::vector<std::string> route_ops;

    ERL_NIF_TERM key, value;

    // Parse exhaustive option
    key = enif_make_atom(env, "exhaustive");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        char buf[32];
        if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1))
        {
            exhaustive = (std::string(buf) == "true");
        }
    }

    // Parse seed option
    key = enif_make_atom(env, "seed");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        enif_get_int64(env, value, &seed);
    }

    // Parse node_operators list
    key = enif_make_atom(env, "node_operators");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        unsigned len;
        if (enif_get_list_length(env, value, &len))
        {
            ERL_NIF_TERM head, tail = value;
            for (unsigned i = 0; i < len; i++)
            {
                enif_get_list_cell(env, tail, &head, &tail);
                char buf[64];
                if (enif_get_atom(env, head, buf, sizeof(buf), ERL_NIF_LATIN1))
                {
                    node_ops.push_back(std::string(buf));
                }
            }
        }
    }

    // Parse route_operators list
    key = enif_make_atom(env, "route_operators");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        unsigned len;
        if (enif_get_list_length(env, value, &len))
        {
            ERL_NIF_TERM head, tail = value;
            for (unsigned i = 0; i < len; i++)
            {
                enif_get_list_cell(env, tail, &head, &tail);
                char buf[64];
                if (enif_get_atom(env, head, buf, sizeof(buf), ERL_NIF_LATIN1))
                {
                    route_ops.push_back(std::string(buf));
                }
            }
        }
    }

    // Build neighbourhood
    auto neighbours = build_neighbours(problem_data);

    // Create perturbation manager with default params
    pyvrp::search::PerturbationParams perturbParams(1, 25);
    pyvrp::search::PerturbationManager perturbManager(perturbParams);

    // Create local search
    pyvrp::search::LocalSearch ls(problem_data, neighbours, perturbManager);

    // Create operators (kept alive in vectors)
    std::vector<std::unique_ptr<pyvrp::search::Exchange<1, 0>>> exchange10_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<1, 1>>> exchange11_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<2, 0>>> exchange20_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<2, 1>>> exchange21_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<2, 2>>> exchange22_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<3, 0>>> exchange30_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<3, 1>>> exchange31_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<3, 2>>> exchange32_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<3, 3>>> exchange33_ops;
    std::vector<std::unique_ptr<pyvrp::search::SwapTails>> swap_tails_ops;
    std::vector<std::unique_ptr<pyvrp::search::RelocateWithDepot>>
        relocate_depot_ops;
    std::vector<std::unique_ptr<pyvrp::search::SwapStar>> swap_star_ops;
    std::vector<std::unique_ptr<pyvrp::search::SwapRoutes>> swap_routes_ops;

    // Add specified node operators
    for (const auto &op_name : node_ops)
    {
        if (op_name == "exchange10" || op_name == "relocate")
        {
            exchange10_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<1, 0>>(problem_data));
            ls.addNodeOperator(*exchange10_ops.back());
        }
        else if (op_name == "exchange11" || op_name == "swap11")
        {
            exchange11_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<1, 1>>(problem_data));
            ls.addNodeOperator(*exchange11_ops.back());
        }
        else if (op_name == "exchange20" || op_name == "relocate2")
        {
            exchange20_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<2, 0>>(problem_data));
            ls.addNodeOperator(*exchange20_ops.back());
        }
        else if (op_name == "exchange21" || op_name == "swap21")
        {
            exchange21_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<2, 1>>(problem_data));
            ls.addNodeOperator(*exchange21_ops.back());
        }
        else if (op_name == "exchange22" || op_name == "swap22")
        {
            exchange22_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<2, 2>>(problem_data));
            ls.addNodeOperator(*exchange22_ops.back());
        }
        else if (op_name == "exchange30" || op_name == "relocate3")
        {
            exchange30_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<3, 0>>(problem_data));
            ls.addNodeOperator(*exchange30_ops.back());
        }
        else if (op_name == "exchange31" || op_name == "swap31")
        {
            exchange31_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<3, 1>>(problem_data));
            ls.addNodeOperator(*exchange31_ops.back());
        }
        else if (op_name == "exchange32" || op_name == "swap32")
        {
            exchange32_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<3, 2>>(problem_data));
            ls.addNodeOperator(*exchange32_ops.back());
        }
        else if (op_name == "exchange33" || op_name == "swap33")
        {
            exchange33_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<3, 3>>(problem_data));
            ls.addNodeOperator(*exchange33_ops.back());
        }
        else if (op_name == "swap_tails")
        {
            swap_tails_ops.push_back(
                std::make_unique<pyvrp::search::SwapTails>(problem_data));
            ls.addNodeOperator(*swap_tails_ops.back());
        }
        else if (op_name == "relocate_with_depot")
        {
            relocate_depot_ops.push_back(
                std::make_unique<pyvrp::search::RelocateWithDepot>(
                    problem_data));
            ls.addNodeOperator(*relocate_depot_ops.back());
        }
    }

    // Add specified route operators
    for (const auto &op_name : route_ops)
    {
        if (op_name == "swap_star")
        {
            swap_star_ops.push_back(
                std::make_unique<pyvrp::search::SwapStar>(problem_data));
            ls.addRouteOperator(*swap_star_ops.back());
        }
        else if (op_name == "swap_routes")
        {
            swap_routes_ops.push_back(
                std::make_unique<pyvrp::search::SwapRoutes>(problem_data));
            ls.addRouteOperator(*swap_routes_ops.back());
        }
    }

    // Create RNG and shuffle (like PyVRP's LocalSearch.__call__ does)
    RandomNumberGenerator rng(static_cast<uint32_t>(seed));
    ls.shuffle(rng);

    // Run local search
    Solution improved
        = ls(solution_resource->solution, cost_evaluator, exhaustive);

    return fine::Ok(fine::make_resource<SolutionResource>(
        std::move(improved), problem_resource->data));
}

FINE_NIF(local_search_with_operators_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// -----------------------------------------------------------------------------
// Operator Statistics Query - returns statistics for each operator after search
// -----------------------------------------------------------------------------

/**
 * Get statistics from local search with specific operators.
 * Returns a map with operator stats: %{moves: n, improving: n, updates: n}
 */
fine::Term local_search_stats_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    fine::ResourcePtr<ProblemDataResource> problem_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource,
    fine::Term opts_term)
{
    auto &problem_data = *problem_resource->data;
    auto &cost_evaluator = evaluator_resource->evaluator;

    // Parse options
    bool exhaustive = false;
    std::vector<std::string> node_ops;
    std::vector<std::string> route_ops;

    ERL_NIF_TERM key, value;

    key = enif_make_atom(env, "exhaustive");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        char buf[32];
        if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1))
        {
            exhaustive = (std::string(buf) == "true");
        }
    }

    key = enif_make_atom(env, "node_operators");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        unsigned len;
        if (enif_get_list_length(env, value, &len))
        {
            ERL_NIF_TERM head, tail = value;
            for (unsigned i = 0; i < len; i++)
            {
                enif_get_list_cell(env, tail, &head, &tail);
                char buf[64];
                if (enif_get_atom(env, head, buf, sizeof(buf), ERL_NIF_LATIN1))
                {
                    node_ops.push_back(std::string(buf));
                }
            }
        }
    }

    key = enif_make_atom(env, "route_operators");
    if (enif_get_map_value(env, opts_term, key, &value))
    {
        unsigned len;
        if (enif_get_list_length(env, value, &len))
        {
            ERL_NIF_TERM head, tail = value;
            for (unsigned i = 0; i < len; i++)
            {
                enif_get_list_cell(env, tail, &head, &tail);
                char buf[64];
                if (enif_get_atom(env, head, buf, sizeof(buf), ERL_NIF_LATIN1))
                {
                    route_ops.push_back(std::string(buf));
                }
            }
        }
    }

    // Build neighbourhood
    auto neighbours = build_neighbours(problem_data);

    // Create perturbation manager with default params
    pyvrp::search::PerturbationParams perturbParams(1, 25);
    pyvrp::search::PerturbationManager perturbManager(perturbParams);

    // Create local search
    pyvrp::search::LocalSearch ls(problem_data, neighbours, perturbManager);

    // Track operators for stats collection
    std::vector<std::pair<std::string, pyvrp::search::NodeOperator *>>
        node_operator_ptrs;
    std::vector<std::pair<std::string, pyvrp::search::RouteOperator *>>
        route_operator_ptrs;

    // Create and add operators
    std::vector<std::unique_ptr<pyvrp::search::Exchange<1, 0>>> exchange10_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<1, 1>>> exchange11_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<2, 0>>> exchange20_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<2, 1>>> exchange21_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<2, 2>>> exchange22_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<3, 0>>> exchange30_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<3, 1>>> exchange31_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<3, 2>>> exchange32_ops;
    std::vector<std::unique_ptr<pyvrp::search::Exchange<3, 3>>> exchange33_ops;
    std::vector<std::unique_ptr<pyvrp::search::SwapTails>> swap_tails_ops;
    std::vector<std::unique_ptr<pyvrp::search::RelocateWithDepot>>
        relocate_depot_ops;
    std::vector<std::unique_ptr<pyvrp::search::SwapStar>> swap_star_ops;
    std::vector<std::unique_ptr<pyvrp::search::SwapRoutes>> swap_routes_ops;

    for (const auto &op_name : node_ops)
    {
        if (op_name == "exchange10" || op_name == "relocate")
        {
            exchange10_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<1, 0>>(problem_data));
            ls.addNodeOperator(*exchange10_ops.back());
            node_operator_ptrs.push_back(
                {op_name, exchange10_ops.back().get()});
        }
        else if (op_name == "exchange11" || op_name == "swap11")
        {
            exchange11_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<1, 1>>(problem_data));
            ls.addNodeOperator(*exchange11_ops.back());
            node_operator_ptrs.push_back(
                {op_name, exchange11_ops.back().get()});
        }
        else if (op_name == "exchange20" || op_name == "relocate2")
        {
            exchange20_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<2, 0>>(problem_data));
            ls.addNodeOperator(*exchange20_ops.back());
            node_operator_ptrs.push_back(
                {op_name, exchange20_ops.back().get()});
        }
        else if (op_name == "exchange21" || op_name == "swap21")
        {
            exchange21_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<2, 1>>(problem_data));
            ls.addNodeOperator(*exchange21_ops.back());
            node_operator_ptrs.push_back(
                {op_name, exchange21_ops.back().get()});
        }
        else if (op_name == "exchange22" || op_name == "swap22")
        {
            exchange22_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<2, 2>>(problem_data));
            ls.addNodeOperator(*exchange22_ops.back());
            node_operator_ptrs.push_back(
                {op_name, exchange22_ops.back().get()});
        }
        else if (op_name == "exchange30" || op_name == "relocate3")
        {
            exchange30_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<3, 0>>(problem_data));
            ls.addNodeOperator(*exchange30_ops.back());
            node_operator_ptrs.push_back(
                {op_name, exchange30_ops.back().get()});
        }
        else if (op_name == "exchange31" || op_name == "swap31")
        {
            exchange31_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<3, 1>>(problem_data));
            ls.addNodeOperator(*exchange31_ops.back());
            node_operator_ptrs.push_back(
                {op_name, exchange31_ops.back().get()});
        }
        else if (op_name == "exchange32" || op_name == "swap32")
        {
            exchange32_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<3, 2>>(problem_data));
            ls.addNodeOperator(*exchange32_ops.back());
            node_operator_ptrs.push_back(
                {op_name, exchange32_ops.back().get()});
        }
        else if (op_name == "exchange33" || op_name == "swap33")
        {
            exchange33_ops.push_back(
                std::make_unique<pyvrp::search::Exchange<3, 3>>(problem_data));
            ls.addNodeOperator(*exchange33_ops.back());
            node_operator_ptrs.push_back(
                {op_name, exchange33_ops.back().get()});
        }
        else if (op_name == "swap_tails")
        {
            swap_tails_ops.push_back(
                std::make_unique<pyvrp::search::SwapTails>(problem_data));
            ls.addNodeOperator(*swap_tails_ops.back());
            node_operator_ptrs.push_back(
                {op_name, swap_tails_ops.back().get()});
        }
        else if (op_name == "relocate_with_depot")
        {
            relocate_depot_ops.push_back(
                std::make_unique<pyvrp::search::RelocateWithDepot>(
                    problem_data));
            ls.addNodeOperator(*relocate_depot_ops.back());
            node_operator_ptrs.push_back(
                {op_name, relocate_depot_ops.back().get()});
        }
    }

    for (const auto &op_name : route_ops)
    {
        if (op_name == "swap_star")
        {
            swap_star_ops.push_back(
                std::make_unique<pyvrp::search::SwapStar>(problem_data));
            ls.addRouteOperator(*swap_star_ops.back());
            route_operator_ptrs.push_back(
                {op_name, swap_star_ops.back().get()});
        }
        else if (op_name == "swap_routes")
        {
            swap_routes_ops.push_back(
                std::make_unique<pyvrp::search::SwapRoutes>(problem_data));
            ls.addRouteOperator(*swap_routes_ops.back());
            route_operator_ptrs.push_back(
                {op_name, swap_routes_ops.back().get()});
        }
    }

    // Run local search
    ls(solution_resource->solution, cost_evaluator, exhaustive);

    // Get LocalSearch statistics
    auto const &ls_stats = ls.statistics();

    // Build result map
    ERL_NIF_TERM result_map = enif_make_new_map(env);

    // Add local search stats
    ERL_NIF_TERM ls_stats_map = enif_make_new_map(env);
    enif_make_map_put(
        env,
        ls_stats_map,
        enif_make_atom(env, "num_moves"),
        enif_make_int64(env, static_cast<int64_t>(ls_stats.numMoves)),
        &ls_stats_map);
    enif_make_map_put(
        env,
        ls_stats_map,
        enif_make_atom(env, "num_improving"),
        enif_make_int64(env, static_cast<int64_t>(ls_stats.numImproving)),
        &ls_stats_map);
    enif_make_map_put(
        env,
        ls_stats_map,
        enif_make_atom(env, "num_updates"),
        enif_make_int64(env, static_cast<int64_t>(ls_stats.numUpdates)),
        &ls_stats_map);

    enif_make_map_put(env,
                      result_map,
                      enif_make_atom(env, "local_search"),
                      ls_stats_map,
                      &result_map);

    // Build operator stats list
    std::vector<ERL_NIF_TERM> op_stats_list;

    for (const auto &[name, op] : node_operator_ptrs)
    {
        auto const &stats = op->statistics();
        ERL_NIF_TERM op_map = enif_make_new_map(env);
        enif_make_map_put(env,
                          op_map,
                          enif_make_atom(env, "name"),
                          enif_make_atom(env, name.c_str()),
                          &op_map);
        enif_make_map_put(
            env,
            op_map,
            enif_make_atom(env, "num_evaluations"),
            enif_make_int64(env, static_cast<int64_t>(stats.numEvaluations)),
            &op_map);
        enif_make_map_put(
            env,
            op_map,
            enif_make_atom(env, "num_applications"),
            enif_make_int64(env, static_cast<int64_t>(stats.numApplications)),
            &op_map);
        op_stats_list.push_back(op_map);
    }

    for (const auto &[name, op] : route_operator_ptrs)
    {
        auto const &stats = op->statistics();
        ERL_NIF_TERM op_map = enif_make_new_map(env);
        enif_make_map_put(env,
                          op_map,
                          enif_make_atom(env, "name"),
                          enif_make_atom(env, name.c_str()),
                          &op_map);
        enif_make_map_put(
            env,
            op_map,
            enif_make_atom(env, "num_evaluations"),
            enif_make_int64(env, static_cast<int64_t>(stats.numEvaluations)),
            &op_map);
        enif_make_map_put(
            env,
            op_map,
            enif_make_atom(env, "num_applications"),
            enif_make_int64(env, static_cast<int64_t>(stats.numApplications)),
            &op_map);
        op_stats_list.push_back(op_map);
    }

    enif_make_map_put(env,
                      result_map,
                      enif_make_atom(env, "operators"),
                      enif_make_list_from_array(
                          env, op_stats_list.data(), op_stats_list.size()),
                      &result_map);

    return fine::Term(result_map);
}

FINE_NIF(local_search_stats_nif, 0);

// -----------------------------------------------------------------------------
// Persistent LocalSearch Resource NIFs
// -----------------------------------------------------------------------------

/**
 * Create a persistent LocalSearch resource.
 *
 * This pre-computes neighbours and creates all operators once, avoiding the
 * O(n²) cost on every iteration. The resource can be reused across iterations.
 *
 * The seed initializes the RNG which is stored and reused across calls,
 * matching PyVRP's behavior where one RNG is created at algorithm start.
 */
fine::ResourcePtr<LocalSearchResource>
create_local_search_nif([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<ProblemDataResource> problem_resource,
                        int64_t seed)
{
    auto &problem_data = *problem_resource->data;

    // Build neighbours (the expensive O(n²) computation)
    auto neighbours = build_neighbours(problem_data);

    return fine::make_resource<LocalSearchResource>(
        problem_resource->data,
        std::move(neighbours),
        static_cast<uint32_t>(seed));
}

FINE_NIF(create_local_search_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND);

/**
 * Run local search using a persistent LocalSearch resource.
 *
 * This avoids recreating neighbours and operators on each call.
 * Uses the stored RNG which advances across calls (matching PyVRP).
 */
fine::Ok<fine::ResourcePtr<SolutionResource>> local_search_run_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<LocalSearchResource> ls_resource,
    fine::ResourcePtr<SolutionResource> solution_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    auto &cost_evaluator = evaluator_resource->evaluator;

    // Shuffle using stored RNG (like Python's __call__ does)
    // The RNG state advances, matching PyVRP's behavior
    ls_resource->ls->shuffle(ls_resource->rng);

    // Run local search (operator() = perturbation + search + intensify loop)
    Solution improved
        = (*ls_resource->ls)(solution_resource->solution, cost_evaluator);

    return fine::Ok(fine::make_resource<SolutionResource>(
        std::move(improved), ls_resource->problemData));
}

FINE_NIF(local_search_run_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND);

/**
 * Run search-only (no perturbation) using a persistent LocalSearch resource.
 *
 * Used for initial solution construction.
 * Uses the stored RNG which advances across calls (matching PyVRP).
 */
fine::Ok<fine::ResourcePtr<SolutionResource>> local_search_search_run_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<LocalSearchResource> ls_resource,
    fine::ResourcePtr<SolutionResource> solution_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    auto &cost_evaluator = evaluator_resource->evaluator;

    // Shuffle using stored RNG
    ls_resource->ls->shuffle(ls_resource->rng);

    // Run search only (no perturbation)
    Solution improved
        = ls_resource->ls->search(solution_resource->solution, cost_evaluator);

    return fine::Ok(fine::make_resource<SolutionResource>(
        std::move(improved), ls_resource->problemData));
}

FINE_NIF(local_search_search_run_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// -----------------------------------------------------------------------------
// search::Route NIFs
// -----------------------------------------------------------------------------

// Create a new search::Route
fine::ResourcePtr<SearchRouteResource>
create_search_route_nif([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<ProblemDataResource> problem_resource,
                        int64_t idx,
                        int64_t vehicle_type)
{
    auto &data = *problem_resource->data;
    auto route = std::make_unique<search::Route>(
        data, static_cast<size_t>(idx), static_cast<size_t>(vehicle_type));

    return fine::make_resource<SearchRouteResource>(std::move(route),
                                                    problem_resource->data);
}

FINE_NIF(create_search_route_nif, 0);

// Get route index
int64_t
search_route_idx_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->idx());
}

FINE_NIF(search_route_idx_nif, 0);

// Get route vehicle type
int64_t search_route_vehicle_type_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->vehicleType());
}

FINE_NIF(search_route_vehicle_type_nif, 0);

// Get number of clients
int64_t search_route_num_clients_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->numClients());
}

FINE_NIF(search_route_num_clients_nif, 0);

// Get number of depots
int64_t search_route_num_depots_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->numDepots());
}

FINE_NIF(search_route_num_depots_nif, 0);

// Get number of trips
int64_t search_route_num_trips_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->numTrips());
}

FINE_NIF(search_route_num_trips_nif, 0);

// Get max trips
int64_t search_route_max_trips_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->maxTrips());
}

FINE_NIF(search_route_max_trips_nif, 0);

// Get route size (total nodes including depots)
int64_t
search_route_size_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->size());
}

FINE_NIF(search_route_size_nif, 0);

// Check if route is empty
bool search_route_empty_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return route_resource->route()->empty();
}

FINE_NIF(search_route_empty_nif, 0);

// Check if route is feasible
bool search_route_is_feasible_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return route_resource->route()->isFeasible();
}

FINE_NIF(search_route_is_feasible_nif, 0);

// Check if route has excess load
bool search_route_has_excess_load_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return route_resource->route()->hasExcessLoad();
}

FINE_NIF(search_route_has_excess_load_nif, 0);

// Check if route has excess distance
bool search_route_has_excess_distance_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return route_resource->route()->hasExcessDistance();
}

FINE_NIF(search_route_has_excess_distance_nif, 0);

// Check if route has time warp
bool search_route_has_time_warp_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return route_resource->route()->hasTimeWarp();
}

FINE_NIF(search_route_has_time_warp_nif, 0);

// Get route distance
int64_t
search_route_distance_nif([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->distance());
}

FINE_NIF(search_route_distance_nif, 0);

// Get route duration
int64_t
search_route_duration_nif([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->duration());
}

FINE_NIF(search_route_duration_nif, 0);

// Get route time warp
int64_t search_route_time_warp_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->timeWarp());
}

FINE_NIF(search_route_time_warp_nif, 0);

// Get route overtime
int64_t
search_route_overtime_nif([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->overtime());
}

FINE_NIF(search_route_overtime_nif, 0);

// Get route excess distance
int64_t search_route_excess_distance_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->excessDistance());
}

FINE_NIF(search_route_excess_distance_nif, 0);

// Get route load (as list)
std::vector<int64_t>
search_route_load_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<SearchRouteResource> route_resource)
{
    auto const &load = route_resource->route()->load();
    std::vector<int64_t> result(load.begin(), load.end());
    return result;
}

FINE_NIF(search_route_load_nif, 0);

// Get route excess load (as list)
std::vector<int64_t> search_route_excess_load_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    auto const &excess = route_resource->route()->excessLoad();
    std::vector<int64_t> result(excess.begin(), excess.end());
    return result;
}

FINE_NIF(search_route_excess_load_nif, 0);

// Get route capacity (as list)
std::vector<int64_t>
search_route_capacity_nif([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<SearchRouteResource> route_resource)
{
    auto const &capacity = route_resource->route()->capacity();
    std::vector<int64_t> result(capacity.begin(), capacity.end());
    return result;
}

FINE_NIF(search_route_capacity_nif, 0);

// Get route start depot
int64_t search_route_start_depot_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->startDepot());
}

FINE_NIF(search_route_start_depot_nif, 0);

// Get route end depot
int64_t search_route_end_depot_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->endDepot());
}

FINE_NIF(search_route_end_depot_nif, 0);

// Get fixed vehicle cost
int64_t search_route_fixed_vehicle_cost_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->fixedVehicleCost());
}

FINE_NIF(search_route_fixed_vehicle_cost_nif, 0);

// Get distance cost
int64_t search_route_distance_cost_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->distanceCost());
}

FINE_NIF(search_route_distance_cost_nif, 0);

// Get duration cost
int64_t search_route_duration_cost_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->durationCost());
}

FINE_NIF(search_route_duration_cost_nif, 0);

// Get unit distance cost
int64_t search_route_unit_distance_cost_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->unitDistanceCost());
}

FINE_NIF(search_route_unit_distance_cost_nif, 0);

// Get unit duration cost
int64_t search_route_unit_duration_cost_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->unitDurationCost());
}

FINE_NIF(search_route_unit_duration_cost_nif, 0);

// Get centroid
std::tuple<double, double>
search_route_centroid_nif([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<SearchRouteResource> route_resource)
{
    auto const &centroid = route_resource->route()->centroid();
    return {static_cast<double>(centroid.first),
            static_cast<double>(centroid.second)};
}

FINE_NIF(search_route_centroid_nif, 0);

// Get profile
int64_t
search_route_profile_nif([[maybe_unused]] ErlNifEnv *env,
                         fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->profile());
}

FINE_NIF(search_route_profile_nif, 0);

// Get node at index
fine::ResourcePtr<SearchNodeResource>
search_route_get_node_nif([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<SearchRouteResource> route_resource,
                          int64_t idx)
{
    auto *node = (*route_resource->route())[static_cast<size_t>(idx)];
    // Node is owned by route - use constructor that keeps route alive
    return fine::make_resource<SearchNodeResource>(node, route_resource->data);
}

FINE_NIF(search_route_get_node_nif, 0);

// Append node to route
fine::Atom
search_route_append_nif([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<SearchRouteResource> route_resource,
                        fine::ResourcePtr<SearchNodeResource> node_resource)
{
    bool needs_transfer = prepare_node_transfer(route_resource, node_resource);
    route_resource->route()->push_back(node_resource->node);
    complete_node_transfer(route_resource, node_resource, needs_transfer);
    return fine::Atom("ok");
}

FINE_NIF(search_route_append_nif, 0);

// Insert node at index
fine::Atom
search_route_insert_nif([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<SearchRouteResource> route_resource,
                        int64_t idx,
                        fine::ResourcePtr<SearchNodeResource> node_resource)
{
    bool needs_transfer = prepare_node_transfer(route_resource, node_resource);
    route_resource->route()->insert(static_cast<size_t>(idx),
                                    node_resource->node);
    complete_node_transfer(route_resource, node_resource, needs_transfer);
    return fine::Atom("ok");
}

FINE_NIF(search_route_insert_nif, 0);

// Remove node at index
fine::Atom
search_route_remove_nif([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<SearchRouteResource> route_resource,
                        int64_t idx)
{
    route_resource->route()->remove(static_cast<size_t>(idx));
    return fine::Atom("ok");
}

FINE_NIF(search_route_remove_nif, 0);

// Clear route
fine::Atom
search_route_clear_nif([[maybe_unused]] ErlNifEnv *env,
                       fine::ResourcePtr<SearchRouteResource> route_resource)
{
    route_resource->route()->clear();
    return fine::Atom("ok");
}

FINE_NIF(search_route_clear_nif, 0);

// Update route (recompute statistics)
fine::Atom
search_route_update_nif([[maybe_unused]] ErlNifEnv *env,
                        fine::ResourcePtr<SearchRouteResource> route_resource)
{
    route_resource->route()->update();
    return fine::Atom("ok");
}

FINE_NIF(search_route_update_nif, 0);

// Static swap nodes - handles all ownership scenarios:
// 1. Both in different routes: swap ownership between routes
// 2. One in route, one standalone: transfer standalone to route, route node
// becomes standalone
// 3. Both standalone: swap owned flags
// 4. Same route: no ownership change needed
fine::Atom
search_route_swap_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<SearchNodeResource> first_resource,
                      fine::ResourcePtr<SearchNodeResource> second_resource)
{
    // Get parent routes before swap (null for standalone nodes)
    auto first_parent = first_resource->parentRoute;
    auto second_parent = second_resource->parentRoute;
    bool first_was_owned = first_resource->owned;
    bool second_was_owned = second_resource->owned;

    // Perform the PyVRP swap (swaps nodes in routes' internal vectors and node
    // metadata)
    search::Route::swap(first_resource->node, second_resource->node);

    // Now handle ownership transfer based on where nodes came from and are
    // going After PyVRP swap: first_resource->node is now where second was,
    // second is where first was

    // Case: same parent (including both null) - no ownership transfer needed
    if (first_parent.get() == second_parent.get())
    {
        return fine::Atom("ok");
    }

    // Case: first was in a route, second was standalone (owned)
    if (first_parent && !second_parent && second_was_owned)
    {
        // second node goes into first's route, first node becomes standalone
        // Transfer second's ownership to first_parent
        first_parent->ownedNodes.push_back(
            std::unique_ptr<search::Route::Node>(second_resource->node));
        second_resource->owned = false;
        second_resource->parentRoute = first_parent;

        // first node is now standalone (second had no route)
        // Need to extract first from first_parent's ownedNodes
        auto &nodes = first_parent->ownedNodes;
        for (auto it = nodes.begin(); it != nodes.end(); ++it)
        {
            if (it->get() == first_resource->node)
            {
                [[maybe_unused]] auto *ptr = it->release();
                nodes.erase(it);
                break;
            }
        }
        first_resource->owned = true;
        first_resource->parentRoute = nullptr;
        return fine::Atom("ok");
    }

    // Case: second was in a route, first was standalone (owned)
    if (second_parent && !first_parent && first_was_owned)
    {
        // first node goes into second's route, second node becomes standalone
        // Transfer first's ownership to second_parent
        second_parent->ownedNodes.push_back(
            std::unique_ptr<search::Route::Node>(first_resource->node));
        first_resource->owned = false;
        first_resource->parentRoute = second_parent;

        // second node is now standalone (first had no route)
        // Need to extract second from second_parent's ownedNodes
        auto &nodes = second_parent->ownedNodes;
        for (auto it = nodes.begin(); it != nodes.end(); ++it)
        {
            if (it->get() == second_resource->node)
            {
                [[maybe_unused]] auto *ptr = it->release();
                nodes.erase(it);
                break;
            }
        }
        second_resource->owned = true;
        second_resource->parentRoute = nullptr;
        return fine::Atom("ok");
    }

    // Case: both in different routes - swap ownership between routes
    if (first_parent && second_parent)
    {
        std::unique_ptr<search::Route::Node> first_owned_ptr;
        std::unique_ptr<search::Route::Node> second_owned_ptr;

        // Extract first node from its old parent's ownedNodes
        auto &first_nodes = first_parent->ownedNodes;
        for (auto it = first_nodes.begin(); it != first_nodes.end(); ++it)
        {
            if (it->get() == first_resource->node)
            {
                first_owned_ptr = std::move(*it);
                first_nodes.erase(it);
                break;
            }
        }

        // Extract second node from its old parent's ownedNodes
        auto &second_nodes = second_parent->ownedNodes;
        for (auto it = second_nodes.begin(); it != second_nodes.end(); ++it)
        {
            if (it->get() == second_resource->node)
            {
                second_owned_ptr = std::move(*it);
                second_nodes.erase(it);
                break;
            }
        }

        // Transfer ownership to new parents (nodes swapped routes)
        if (first_owned_ptr)
        {
            second_nodes.push_back(std::move(first_owned_ptr));
        }
        if (second_owned_ptr)
        {
            first_nodes.push_back(std::move(second_owned_ptr));
        }

        // Update parent references (swap them)
        first_resource->parentRoute = second_parent;
        second_resource->parentRoute = first_parent;
        return fine::Atom("ok");
    }

    // Case: both standalone - just swap owned flags (both should be true, no
    // change) Nothing to do - both remain owned by their respective
    // SearchNodeResources

    return fine::Atom("ok");
}

FINE_NIF(search_route_swap_nif, 0);

// Check if routes overlap with given tolerance
bool search_route_overlaps_with_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route1_resource,
    fine::ResourcePtr<SearchRouteResource> route2_resource,
    double tolerance)
{
    return route1_resource->route()->overlapsWith(*route2_resource->route(),
                                                  tolerance);
}

FINE_NIF(search_route_overlaps_with_nif, 0);

// Get shift duration
int64_t search_route_shift_duration_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->shiftDuration());
}

FINE_NIF(search_route_shift_duration_nif, 0);

// Get max overtime
int64_t search_route_max_overtime_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->maxOvertime());
}

FINE_NIF(search_route_max_overtime_nif, 0);

// Get max duration (shift_duration + max_overtime)
int64_t search_route_max_duration_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->maxDuration());
}

FINE_NIF(search_route_max_duration_nif, 0);

// Get unit overtime cost
int64_t search_route_unit_overtime_cost_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return static_cast<int64_t>(route_resource->route()->unitOvertimeCost());
}

FINE_NIF(search_route_unit_overtime_cost_nif, 0);

// Check if route has distance cost
bool search_route_has_distance_cost_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return route_resource->route()->hasDistanceCost();
}

FINE_NIF(search_route_has_distance_cost_nif, 0);

// Check if route has duration cost
bool search_route_has_duration_cost_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource)
{
    return route_resource->route()->hasDurationCost();
}

FINE_NIF(search_route_has_duration_cost_nif, 0);

// Get distance between two indices (with optional profile)
int64_t search_route_dist_between_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource,
    int64_t start,
    int64_t end,
    int64_t profile)
{
    auto &route = *route_resource->route();
    size_t p = (profile < 0) ? route.profile() : static_cast<size_t>(profile);
    return static_cast<int64_t>(
        route.between(static_cast<size_t>(start), static_cast<size_t>(end))
            .distance(p));
}

FINE_NIF(search_route_dist_between_nif, 0);

// Get distance at specific index
int64_t
search_route_dist_at_nif([[maybe_unused]] ErlNifEnv *env,
                         fine::ResourcePtr<SearchRouteResource> route_resource,
                         int64_t idx,
                         int64_t profile)
{
    auto &route = *route_resource->route();
    size_t p = (profile < 0) ? route.profile() : static_cast<size_t>(profile);
    return static_cast<int64_t>(route.at(static_cast<size_t>(idx)).distance(p));
}

FINE_NIF(search_route_dist_at_nif, 0);

// Get distance before index
int64_t search_route_dist_before_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource,
    int64_t idx)
{
    auto &route = *route_resource->route();
    return static_cast<int64_t>(
        route.before(static_cast<size_t>(idx)).distance(route.profile()));
}

FINE_NIF(search_route_dist_before_nif, 0);

// Get distance after index
int64_t search_route_dist_after_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchRouteResource> route_resource,
    int64_t idx)
{
    auto &route = *route_resource->route();
    return static_cast<int64_t>(
        route.after(static_cast<size_t>(idx)).distance(route.profile()));
}

FINE_NIF(search_route_dist_after_nif, 0);

// -----------------------------------------------------------------------------
// search::Route::Node NIFs
// -----------------------------------------------------------------------------

// Create a new Node
fine::ResourcePtr<SearchNodeResource>
create_search_node_nif([[maybe_unused]] ErlNifEnv *env,
                       fine::ResourcePtr<ProblemDataResource> problem_resource,
                       int64_t loc)
{
    auto *node = new search::Route::Node(static_cast<size_t>(loc));
    return fine::make_resource<SearchNodeResource>(node,
                                                   true,  // We own this node
                                                   problem_resource->data);
}

FINE_NIF(create_search_node_nif, 0);

// Get node's location (client)
int64_t
search_node_client_nif([[maybe_unused]] ErlNifEnv *env,
                       fine::ResourcePtr<SearchNodeResource> node_resource)
{
    return static_cast<int64_t>(node_resource->node->client());
}

FINE_NIF(search_node_client_nif, 0);

// Get node's index in route
int64_t search_node_idx_nif([[maybe_unused]] ErlNifEnv *env,
                            fine::ResourcePtr<SearchNodeResource> node_resource)
{
    return static_cast<int64_t>(node_resource->node->idx());
}

FINE_NIF(search_node_idx_nif, 0);

// Get node's trip
int64_t
search_node_trip_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<SearchNodeResource> node_resource)
{
    return static_cast<int64_t>(node_resource->node->trip());
}

FINE_NIF(search_node_trip_nif, 0);

// Check if node is a depot
bool search_node_is_depot_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchNodeResource> node_resource)
{
    return node_resource->node->isDepot();
}

FINE_NIF(search_node_is_depot_nif, 0);

// Check if node is start depot
bool search_node_is_start_depot_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchNodeResource> node_resource)
{
    return node_resource->node->isStartDepot();
}

FINE_NIF(search_node_is_start_depot_nif, 0);

// Check if node is end depot
bool search_node_is_end_depot_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchNodeResource> node_resource)
{
    return node_resource->node->isEndDepot();
}

FINE_NIF(search_node_is_end_depot_nif, 0);

// Check if node is reload depot
bool search_node_is_reload_depot_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchNodeResource> node_resource)
{
    return node_resource->node->isReloadDepot();
}

FINE_NIF(search_node_is_reload_depot_nif, 0);

// Check if node has a route assigned
bool search_node_has_route_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SearchNodeResource> node_resource)
{
    return node_resource->node->route() != nullptr;
}

FINE_NIF(search_node_has_route_nif, 0);

// -----------------------------------------------------------------------------
// Exchange Operator NIFs
// -----------------------------------------------------------------------------

// Create Exchange10 (relocate) operator
fine::ResourcePtr<Exchange10Resource>
create_exchange10_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::Exchange<1, 0>>(data);
    return fine::make_resource<Exchange10Resource>(std::move(op),
                                                   problem_resource->data);
}

FINE_NIF(create_exchange10_nif, 0);

// Create Exchange11 (swap) operator
fine::ResourcePtr<Exchange11Resource>
create_exchange11_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::Exchange<1, 1>>(data);
    return fine::make_resource<Exchange11Resource>(std::move(op),
                                                   problem_resource->data);
}

FINE_NIF(create_exchange11_nif, 0);

// Create Exchange20 operator
fine::ResourcePtr<Exchange20Resource>
create_exchange20_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::Exchange<2, 0>>(data);
    return fine::make_resource<Exchange20Resource>(std::move(op),
                                                   problem_resource->data);
}

FINE_NIF(create_exchange20_nif, 0);

// Create Exchange21 operator
fine::ResourcePtr<Exchange21Resource>
create_exchange21_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::Exchange<2, 1>>(data);
    return fine::make_resource<Exchange21Resource>(std::move(op),
                                                   problem_resource->data);
}

FINE_NIF(create_exchange21_nif, 0);

// Create Exchange22 operator
fine::ResourcePtr<Exchange22Resource>
create_exchange22_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::Exchange<2, 2>>(data);
    return fine::make_resource<Exchange22Resource>(std::move(op),
                                                   problem_resource->data);
}

FINE_NIF(create_exchange22_nif, 0);

// Create Exchange30 operator
fine::ResourcePtr<Exchange30Resource>
create_exchange30_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::Exchange<3, 0>>(data);
    return fine::make_resource<Exchange30Resource>(std::move(op),
                                                   problem_resource->data);
}

FINE_NIF(create_exchange30_nif, 0);

// Create Exchange31 operator
fine::ResourcePtr<Exchange31Resource>
create_exchange31_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::Exchange<3, 1>>(data);
    return fine::make_resource<Exchange31Resource>(std::move(op),
                                                   problem_resource->data);
}

FINE_NIF(create_exchange31_nif, 0);

// Create Exchange32 operator
fine::ResourcePtr<Exchange32Resource>
create_exchange32_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::Exchange<3, 2>>(data);
    return fine::make_resource<Exchange32Resource>(std::move(op),
                                                   problem_resource->data);
}

FINE_NIF(create_exchange32_nif, 0);

// Create Exchange33 operator
fine::ResourcePtr<Exchange33Resource>
create_exchange33_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::Exchange<3, 3>>(data);
    return fine::make_resource<Exchange33Resource>(std::move(op),
                                                   problem_resource->data);
}

FINE_NIF(create_exchange33_nif, 0);

// Exchange10 evaluate
int64_t exchange10_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<Exchange10Resource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(op_resource->op->evaluate(
        u_resource->node, v_resource->node, evaluator_resource->evaluator));
}

FINE_NIF(exchange10_evaluate_nif, 0);

// Exchange10 apply
fine::Atom
exchange10_apply_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<Exchange10Resource> op_resource,
                     fine::ResourcePtr<SearchNodeResource> u_resource,
                     fine::ResourcePtr<SearchNodeResource> v_resource)
{
    op_resource->op->apply(u_resource->node, v_resource->node);
    if (u_resource->parentRoute && v_resource->parentRoute)
    {
        reconcile_route_ownership(u_resource->parentRoute,
                                  v_resource->parentRoute);
    }
    return fine::Atom("ok");
}

FINE_NIF(exchange10_apply_nif, 0);

// Exchange11 evaluate
int64_t exchange11_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<Exchange11Resource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(op_resource->op->evaluate(
        u_resource->node, v_resource->node, evaluator_resource->evaluator));
}

FINE_NIF(exchange11_evaluate_nif, 0);

// Exchange11 apply
fine::Atom
exchange11_apply_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<Exchange11Resource> op_resource,
                     fine::ResourcePtr<SearchNodeResource> u_resource,
                     fine::ResourcePtr<SearchNodeResource> v_resource)
{
    op_resource->op->apply(u_resource->node, v_resource->node);
    if (u_resource->parentRoute && v_resource->parentRoute)
    {
        reconcile_route_ownership(u_resource->parentRoute,
                                  v_resource->parentRoute);
    }
    return fine::Atom("ok");
}

FINE_NIF(exchange11_apply_nif, 0);

// Exchange20 evaluate
int64_t exchange20_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<Exchange20Resource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(op_resource->op->evaluate(
        u_resource->node, v_resource->node, evaluator_resource->evaluator));
}

FINE_NIF(exchange20_evaluate_nif, 0);

// Exchange20 apply
fine::Atom
exchange20_apply_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<Exchange20Resource> op_resource,
                     fine::ResourcePtr<SearchNodeResource> u_resource,
                     fine::ResourcePtr<SearchNodeResource> v_resource)
{
    op_resource->op->apply(u_resource->node, v_resource->node);
    if (u_resource->parentRoute && v_resource->parentRoute)
    {
        reconcile_route_ownership(u_resource->parentRoute,
                                  v_resource->parentRoute);
    }
    return fine::Atom("ok");
}

FINE_NIF(exchange20_apply_nif, 0);

// Exchange21 evaluate
int64_t exchange21_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<Exchange21Resource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(op_resource->op->evaluate(
        u_resource->node, v_resource->node, evaluator_resource->evaluator));
}

FINE_NIF(exchange21_evaluate_nif, 0);

// Exchange21 apply
fine::Atom
exchange21_apply_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<Exchange21Resource> op_resource,
                     fine::ResourcePtr<SearchNodeResource> u_resource,
                     fine::ResourcePtr<SearchNodeResource> v_resource)
{
    op_resource->op->apply(u_resource->node, v_resource->node);
    if (u_resource->parentRoute && v_resource->parentRoute)
    {
        reconcile_route_ownership(u_resource->parentRoute,
                                  v_resource->parentRoute);
    }
    return fine::Atom("ok");
}

FINE_NIF(exchange21_apply_nif, 0);

// Exchange22 evaluate
int64_t exchange22_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<Exchange22Resource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(op_resource->op->evaluate(
        u_resource->node, v_resource->node, evaluator_resource->evaluator));
}

FINE_NIF(exchange22_evaluate_nif, 0);

// Exchange22 apply
fine::Atom
exchange22_apply_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<Exchange22Resource> op_resource,
                     fine::ResourcePtr<SearchNodeResource> u_resource,
                     fine::ResourcePtr<SearchNodeResource> v_resource)
{
    op_resource->op->apply(u_resource->node, v_resource->node);
    if (u_resource->parentRoute && v_resource->parentRoute)
    {
        reconcile_route_ownership(u_resource->parentRoute,
                                  v_resource->parentRoute);
    }
    return fine::Atom("ok");
}

FINE_NIF(exchange22_apply_nif, 0);

// Exchange30 evaluate
int64_t exchange30_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<Exchange30Resource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(op_resource->op->evaluate(
        u_resource->node, v_resource->node, evaluator_resource->evaluator));
}

FINE_NIF(exchange30_evaluate_nif, 0);

// Exchange30 apply
fine::Atom
exchange30_apply_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<Exchange30Resource> op_resource,
                     fine::ResourcePtr<SearchNodeResource> u_resource,
                     fine::ResourcePtr<SearchNodeResource> v_resource)
{
    op_resource->op->apply(u_resource->node, v_resource->node);
    if (u_resource->parentRoute && v_resource->parentRoute)
    {
        reconcile_route_ownership(u_resource->parentRoute,
                                  v_resource->parentRoute);
    }
    return fine::Atom("ok");
}

FINE_NIF(exchange30_apply_nif, 0);

// Exchange31 evaluate
int64_t exchange31_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<Exchange31Resource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(op_resource->op->evaluate(
        u_resource->node, v_resource->node, evaluator_resource->evaluator));
}

FINE_NIF(exchange31_evaluate_nif, 0);

// Exchange31 apply
fine::Atom
exchange31_apply_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<Exchange31Resource> op_resource,
                     fine::ResourcePtr<SearchNodeResource> u_resource,
                     fine::ResourcePtr<SearchNodeResource> v_resource)
{
    op_resource->op->apply(u_resource->node, v_resource->node);
    if (u_resource->parentRoute && v_resource->parentRoute)
    {
        reconcile_route_ownership(u_resource->parentRoute,
                                  v_resource->parentRoute);
    }
    return fine::Atom("ok");
}

FINE_NIF(exchange31_apply_nif, 0);

// Exchange32 evaluate
int64_t exchange32_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<Exchange32Resource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(op_resource->op->evaluate(
        u_resource->node, v_resource->node, evaluator_resource->evaluator));
}

FINE_NIF(exchange32_evaluate_nif, 0);

// Exchange32 apply
fine::Atom
exchange32_apply_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<Exchange32Resource> op_resource,
                     fine::ResourcePtr<SearchNodeResource> u_resource,
                     fine::ResourcePtr<SearchNodeResource> v_resource)
{
    op_resource->op->apply(u_resource->node, v_resource->node);
    if (u_resource->parentRoute && v_resource->parentRoute)
    {
        reconcile_route_ownership(u_resource->parentRoute,
                                  v_resource->parentRoute);
    }
    return fine::Atom("ok");
}

FINE_NIF(exchange32_apply_nif, 0);

// Exchange33 evaluate
int64_t exchange33_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<Exchange33Resource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(op_resource->op->evaluate(
        u_resource->node, v_resource->node, evaluator_resource->evaluator));
}

FINE_NIF(exchange33_evaluate_nif, 0);

// Exchange33 apply
fine::Atom
exchange33_apply_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<Exchange33Resource> op_resource,
                     fine::ResourcePtr<SearchNodeResource> u_resource,
                     fine::ResourcePtr<SearchNodeResource> v_resource)
{
    op_resource->op->apply(u_resource->node, v_resource->node);
    if (u_resource->parentRoute && v_resource->parentRoute)
    {
        reconcile_route_ownership(u_resource->parentRoute,
                                  v_resource->parentRoute);
    }
    return fine::Atom("ok");
}

FINE_NIF(exchange33_apply_nif, 0);

// Create SwapStar operator with optional overlap_tolerance
fine::ResourcePtr<SwapStarResource>
create_swap_star_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<ProblemDataResource> problem_resource,
                     double overlap_tolerance)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::SwapStar>(data, overlap_tolerance);
    return fine::make_resource<SwapStarResource>(std::move(op),
                                                 problem_resource->data);
}

FINE_NIF(create_swap_star_nif, 0);

// Create SwapRoutes operator
fine::ResourcePtr<SwapRoutesResource>
create_swap_routes_nif([[maybe_unused]] ErlNifEnv *env,
                       fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::SwapRoutes>(data);
    return fine::make_resource<SwapRoutesResource>(std::move(op),
                                                   problem_resource->data);
}

FINE_NIF(create_swap_routes_nif, 0);

// SwapStar evaluate (takes two Routes, not Nodes)
int64_t swap_star_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SwapStarResource> op_resource,
    fine::ResourcePtr<SearchRouteResource> route1_resource,
    fine::ResourcePtr<SearchRouteResource> route2_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(
        op_resource->op->evaluate(route1_resource->route(),
                                  route2_resource->route(),
                                  evaluator_resource->evaluator));
}

FINE_NIF(swap_star_evaluate_nif, 0);

// SwapStar apply (takes two Routes) - reconciles ownership after apply
fine::Atom
swap_star_apply_nif([[maybe_unused]] ErlNifEnv *env,
                    fine::ResourcePtr<SwapStarResource> op_resource,
                    fine::ResourcePtr<SearchRouteResource> route1_resource,
                    fine::ResourcePtr<SearchRouteResource> route2_resource)
{
    op_resource->op->apply(route1_resource->route(), route2_resource->route());
    reconcile_route_ownership(route1_resource, route2_resource);
    return fine::Atom("ok");
}

FINE_NIF(swap_star_apply_nif, 0);

// SwapRoutes evaluate (takes two Routes, not Nodes)
int64_t swap_routes_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SwapRoutesResource> op_resource,
    fine::ResourcePtr<SearchRouteResource> route1_resource,
    fine::ResourcePtr<SearchRouteResource> route2_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(
        op_resource->op->evaluate(route1_resource->route(),
                                  route2_resource->route(),
                                  evaluator_resource->evaluator));
}

FINE_NIF(swap_routes_evaluate_nif, 0);

// SwapRoutes apply (takes two Routes) - reconciles ownership after apply
fine::Atom
swap_routes_apply_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<SwapRoutesResource> op_resource,
                      fine::ResourcePtr<SearchRouteResource> route1_resource,
                      fine::ResourcePtr<SearchRouteResource> route2_resource)
{
    op_resource->op->apply(route1_resource->route(), route2_resource->route());
    reconcile_route_ownership(route1_resource, route2_resource);
    return fine::Atom("ok");
}

FINE_NIF(swap_routes_apply_nif, 0);

// Create SwapTails operator
fine::ResourcePtr<SwapTailsResource>
create_swap_tails_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::SwapTails>(data);
    return fine::make_resource<SwapTailsResource>(std::move(op),
                                                  problem_resource->data);
}

FINE_NIF(create_swap_tails_nif, 0);

// Create RelocateWithDepot operator
fine::ResourcePtr<RelocateWithDepotResource> create_relocate_with_depot_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    auto &data = *problem_resource->data;
    auto op = std::make_unique<search::RelocateWithDepot>(data);
    return fine::make_resource<RelocateWithDepotResource>(
        std::move(op), problem_resource->data);
}

FINE_NIF(create_relocate_with_depot_nif, 0);

// SwapTails evaluate
int64_t swap_tails_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<SwapTailsResource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(op_resource->op->evaluate(
        u_resource->node, v_resource->node, evaluator_resource->evaluator));
}

FINE_NIF(swap_tails_evaluate_nif, 0);

// SwapTails apply - reconciles ownership after apply using parent routes from
// nodes
fine::Atom
swap_tails_apply_nif([[maybe_unused]] ErlNifEnv *env,
                     fine::ResourcePtr<SwapTailsResource> op_resource,
                     fine::ResourcePtr<SearchNodeResource> u_resource,
                     fine::ResourcePtr<SearchNodeResource> v_resource)
{
    op_resource->op->apply(u_resource->node, v_resource->node);

    // Reconcile ownership if both nodes have parent routes
    if (u_resource->parentRoute && v_resource->parentRoute)
    {
        reconcile_route_ownership(u_resource->parentRoute,
                                  v_resource->parentRoute);
    }
    return fine::Atom("ok");
}

FINE_NIF(swap_tails_apply_nif, 0);

// RelocateWithDepot evaluate
int64_t relocate_with_depot_evaluate_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<RelocateWithDepotResource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(op_resource->op->evaluate(
        u_resource->node, v_resource->node, evaluator_resource->evaluator));
}

FINE_NIF(relocate_with_depot_evaluate_nif, 0);

// RelocateWithDepot apply
fine::Atom relocate_with_depot_apply_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<RelocateWithDepotResource> op_resource,
    fine::ResourcePtr<SearchNodeResource> u_resource,
    fine::ResourcePtr<SearchNodeResource> v_resource)
{
    op_resource->op->apply(u_resource->node, v_resource->node);
    return fine::Atom("ok");
}

FINE_NIF(relocate_with_depot_apply_nif, 0);

// Check if RelocateWithDepot is supported for the given problem data
bool relocate_with_depot_supports_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    return pyvrp::search::supports<pyvrp::search::RelocateWithDepot>(
        *problem_resource->data);
}

FINE_NIF(relocate_with_depot_supports_nif, 0);

// Helper function to create search route from visits
fine::ResourcePtr<SearchRouteResource>
make_search_route_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<ProblemDataResource> problem_resource,
                      std::vector<int64_t> visits,
                      int64_t idx,
                      int64_t vehicle_type)
{
    auto &data = *problem_resource->data;

    auto route_resource = fine::make_resource<SearchRouteResource>(
        std::make_unique<search::Route>(
            data, static_cast<size_t>(idx), static_cast<size_t>(vehicle_type)),
        problem_resource->data);

    // Create and append nodes for each client visit
    for (int64_t loc : visits)
    {
        auto node
            = std::make_unique<search::Route::Node>(static_cast<size_t>(loc));
        route_resource->route()->push_back(node.get());
        route_resource->ownedNodes().push_back(std::move(node));
    }

    route_resource->route()->update();
    return route_resource;
}

FINE_NIF(make_search_route_nif, 0);

// -----------------------------------------------------------------------------
// Primitive Cost Functions
// -----------------------------------------------------------------------------

// insert_cost: delta cost of inserting U after V
int64_t
insert_cost_nif([[maybe_unused]] ErlNifEnv *env,
                fine::ResourcePtr<SearchNodeResource> u_resource,
                fine::ResourcePtr<SearchNodeResource> v_resource,
                fine::ResourcePtr<ProblemDataResource> problem_resource,
                fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(
        search::insertCost(u_resource->node,
                           v_resource->node,
                           *problem_resource->data,
                           evaluator_resource->evaluator));
}

FINE_NIF(insert_cost_nif, 0);

// remove_cost: delta cost of removing U from its route
int64_t
remove_cost_nif([[maybe_unused]] ErlNifEnv *env,
                fine::ResourcePtr<SearchNodeResource> u_resource,
                fine::ResourcePtr<ProblemDataResource> problem_resource,
                fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(
        search::removeCost(u_resource->node,
                           *problem_resource->data,
                           evaluator_resource->evaluator));
}

FINE_NIF(remove_cost_nif, 0);

// inplace_cost: delta cost of inserting U in place of V
int64_t
inplace_cost_nif([[maybe_unused]] ErlNifEnv *env,
                 fine::ResourcePtr<SearchNodeResource> u_resource,
                 fine::ResourcePtr<SearchNodeResource> v_resource,
                 fine::ResourcePtr<ProblemDataResource> problem_resource,
                 fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(
        search::inplaceCost(u_resource->node,
                            v_resource->node,
                            *problem_resource->data,
                            evaluator_resource->evaluator));
}

FINE_NIF(inplace_cost_nif, 0);

// -----------------------------------------------------------------------------
// RandomNumberGenerator NIFs
// -----------------------------------------------------------------------------

// Create RNG from seed
fine::ResourcePtr<RNGResource>
create_rng_from_seed_nif([[maybe_unused]] ErlNifEnv *env, uint64_t seed)
{
    return fine::make_resource<RNGResource>(static_cast<uint32_t>(seed));
}

FINE_NIF(create_rng_from_seed_nif, 0);

// Create RNG from state (4-element list)
fine::Ok<fine::ResourcePtr<RNGResource>>
create_rng_from_state_nif([[maybe_unused]] ErlNifEnv *env,
                          std::vector<uint64_t> state_vec)
{
    if (state_vec.size() != 4)
    {
        throw std::runtime_error("RNG state must have exactly 4 elements");
    }
    std::array<uint32_t, 4> state = {static_cast<uint32_t>(state_vec[0]),
                                     static_cast<uint32_t>(state_vec[1]),
                                     static_cast<uint32_t>(state_vec[2]),
                                     static_cast<uint32_t>(state_vec[3])};
    return fine::Ok(fine::make_resource<RNGResource>(state));
}

FINE_NIF(create_rng_from_state_nif, 0);

// Get min value (static method - returns 0)
uint64_t rng_min_nif([[maybe_unused]] ErlNifEnv *env)
{
    return static_cast<uint64_t>(RandomNumberGenerator::min());
}

FINE_NIF(rng_min_nif, 0);

// Get max value (static method - returns UINT32_MAX)
uint64_t rng_max_nif([[maybe_unused]] ErlNifEnv *env)
{
    return static_cast<uint64_t>(RandomNumberGenerator::max());
}

FINE_NIF(rng_max_nif, 0);

// Call RNG to get next random uint32 - returns {new_rng, value}
std::tuple<fine::ResourcePtr<RNGResource>, uint64_t>
rng_call_nif([[maybe_unused]] ErlNifEnv *env,
             fine::ResourcePtr<RNGResource> rng_resource)
{
    // Create a new RNG resource with copy of state
    auto new_rng = fine::make_resource<RNGResource>(rng_resource->rng.state());
    uint32_t value = new_rng->rng();
    return std::make_tuple(new_rng, static_cast<uint64_t>(value));
}

FINE_NIF(rng_call_nif, 0);

// Get random float in [0, 1] - returns {new_rng, value}
std::tuple<fine::ResourcePtr<RNGResource>, double>
rng_rand_nif([[maybe_unused]] ErlNifEnv *env,
             fine::ResourcePtr<RNGResource> rng_resource)
{
    // Create a new RNG resource with copy of state
    auto new_rng = fine::make_resource<RNGResource>(rng_resource->rng.state());
    double value = new_rng->rng.rand();
    return std::make_tuple(new_rng, value);
}

FINE_NIF(rng_rand_nif, 0);

// Get random int in [0, high) - returns {new_rng, value}
std::tuple<fine::ResourcePtr<RNGResource>, uint64_t>
rng_randint_nif([[maybe_unused]] ErlNifEnv *env,
                fine::ResourcePtr<RNGResource> rng_resource,
                uint64_t high)
{
    // Create a new RNG resource with copy of state
    auto new_rng = fine::make_resource<RNGResource>(rng_resource->rng.state());
    uint32_t value = new_rng->rng.randint(static_cast<uint32_t>(high));
    return std::make_tuple(new_rng, static_cast<uint64_t>(value));
}

FINE_NIF(rng_randint_nif, 0);

// Get current state as 4-element list
std::vector<uint64_t> rng_state_nif([[maybe_unused]] ErlNifEnv *env,
                                    fine::ResourcePtr<RNGResource> rng_resource)
{
    auto &state = rng_resource->rng.state();
    return std::vector<uint64_t>{state[0], state[1], state[2], state[3]};
}

FINE_NIF(rng_state_nif, 0);

// -----------------------------------------------------------------------------
// DynamicBitset NIFs
// -----------------------------------------------------------------------------

// Create a new bitset with the given number of bits
fine::ResourcePtr<DynamicBitsetResource>
create_dynamic_bitset_nif([[maybe_unused]] ErlNifEnv *env, uint64_t num_bits)
{
    return fine::make_resource<DynamicBitsetResource>(
        static_cast<size_t>(num_bits));
}

FINE_NIF(create_dynamic_bitset_nif, 0);

// Get the size (length) of the bitset
uint64_t
dynamic_bitset_len_nif([[maybe_unused]] ErlNifEnv *env,
                       fine::ResourcePtr<DynamicBitsetResource> bitset_resource)
{
    return static_cast<uint64_t>(bitset_resource->bitset.size());
}

FINE_NIF(dynamic_bitset_len_nif, 0);

// Get a bit at the given index
bool dynamic_bitset_get_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DynamicBitsetResource> bitset_resource,
    uint64_t idx)
{
    return bitset_resource->bitset[static_cast<size_t>(idx)];
}

FINE_NIF(dynamic_bitset_get_nif, 0);

// Set a bit at the given index - returns new bitset (immutable interface)
fine::ResourcePtr<DynamicBitsetResource> dynamic_bitset_set_bit_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DynamicBitsetResource> bitset_resource,
    uint64_t idx,
    bool value)
{
    // Create a copy of the bitset
    auto new_bitset
        = fine::make_resource<DynamicBitsetResource>(bitset_resource->bitset);
    new_bitset->bitset[static_cast<size_t>(idx)] = value;
    return new_bitset;
}

FINE_NIF(dynamic_bitset_set_bit_nif, 0);

// Check if all bits are set
bool dynamic_bitset_all_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DynamicBitsetResource> bitset_resource)
{
    return bitset_resource->bitset.all();
}

FINE_NIF(dynamic_bitset_all_nif, 0);

// Check if any bit is set
bool dynamic_bitset_any_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DynamicBitsetResource> bitset_resource)
{
    return bitset_resource->bitset.any();
}

FINE_NIF(dynamic_bitset_any_nif, 0);

// Check if no bits are set
bool dynamic_bitset_none_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DynamicBitsetResource> bitset_resource)
{
    return bitset_resource->bitset.none();
}

FINE_NIF(dynamic_bitset_none_nif, 0);

// Count the number of set bits
uint64_t dynamic_bitset_count_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DynamicBitsetResource> bitset_resource)
{
    return static_cast<uint64_t>(bitset_resource->bitset.count());
}

FINE_NIF(dynamic_bitset_count_nif, 0);

// Set all bits to 1 - returns new bitset (immutable interface)
fine::ResourcePtr<DynamicBitsetResource> dynamic_bitset_set_all_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DynamicBitsetResource> bitset_resource)
{
    auto new_bitset
        = fine::make_resource<DynamicBitsetResource>(bitset_resource->bitset);
    new_bitset->bitset.set();
    return new_bitset;
}

FINE_NIF(dynamic_bitset_set_all_nif, 0);

// Reset all bits to 0 - returns new bitset (immutable interface)
fine::ResourcePtr<DynamicBitsetResource> dynamic_bitset_reset_all_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DynamicBitsetResource> bitset_resource)
{
    auto new_bitset
        = fine::make_resource<DynamicBitsetResource>(bitset_resource->bitset);
    new_bitset->bitset.reset();
    return new_bitset;
}

FINE_NIF(dynamic_bitset_reset_all_nif, 0);

// Bitwise OR - returns new bitset
fine::ResourcePtr<DynamicBitsetResource>
dynamic_bitset_or_nif([[maybe_unused]] ErlNifEnv *env,
                      fine::ResourcePtr<DynamicBitsetResource> a_resource,
                      fine::ResourcePtr<DynamicBitsetResource> b_resource)
{
    DynamicBitset result = a_resource->bitset | b_resource->bitset;
    return fine::make_resource<DynamicBitsetResource>(std::move(result));
}

FINE_NIF(dynamic_bitset_or_nif, 0);

// Bitwise AND - returns new bitset
fine::ResourcePtr<DynamicBitsetResource>
dynamic_bitset_and_nif([[maybe_unused]] ErlNifEnv *env,
                       fine::ResourcePtr<DynamicBitsetResource> a_resource,
                       fine::ResourcePtr<DynamicBitsetResource> b_resource)
{
    DynamicBitset result = a_resource->bitset & b_resource->bitset;
    return fine::make_resource<DynamicBitsetResource>(std::move(result));
}

FINE_NIF(dynamic_bitset_and_nif, 0);

// Bitwise XOR - returns new bitset
fine::ResourcePtr<DynamicBitsetResource>
dynamic_bitset_xor_nif([[maybe_unused]] ErlNifEnv *env,
                       fine::ResourcePtr<DynamicBitsetResource> a_resource,
                       fine::ResourcePtr<DynamicBitsetResource> b_resource)
{
    DynamicBitset result = a_resource->bitset ^ b_resource->bitset;
    return fine::make_resource<DynamicBitsetResource>(std::move(result));
}

FINE_NIF(dynamic_bitset_xor_nif, 0);

// Bitwise NOT - returns new bitset
fine::ResourcePtr<DynamicBitsetResource>
dynamic_bitset_not_nif([[maybe_unused]] ErlNifEnv *env,
                       fine::ResourcePtr<DynamicBitsetResource> bitset_resource)
{
    DynamicBitset result = ~bitset_resource->bitset;
    return fine::make_resource<DynamicBitsetResource>(std::move(result));
}

FINE_NIF(dynamic_bitset_not_nif, 0);

// Equality check
bool dynamic_bitset_eq_nif([[maybe_unused]] ErlNifEnv *env,
                           fine::ResourcePtr<DynamicBitsetResource> a_resource,
                           fine::ResourcePtr<DynamicBitsetResource> b_resource)
{
    return a_resource->bitset == b_resource->bitset;
}

FINE_NIF(dynamic_bitset_eq_nif, 0);

// -----------------------------------------------------------------------------
// DurationSegment NIFs
// -----------------------------------------------------------------------------

// Create a DurationSegment from raw parameters
fine::ResourcePtr<DurationSegmentResource>
create_duration_segment_nif([[maybe_unused]] ErlNifEnv *env,
                            int64_t duration,
                            int64_t time_warp,
                            int64_t start_early,
                            int64_t start_late,
                            int64_t release_time,
                            int64_t cum_duration,
                            int64_t cum_time_warp,
                            int64_t prev_end_late)
{
    DurationSegment seg{Duration{duration},
                        Duration{time_warp},
                        Duration{start_early},
                        Duration{start_late},
                        Duration{release_time},
                        Duration{cum_duration},
                        Duration{cum_time_warp},
                        Duration{prev_end_late}};
    return fine::make_resource<DurationSegmentResource>(seg);
}

FINE_NIF(create_duration_segment_nif, 0);

// Static merge of two segments with edge duration
fine::ResourcePtr<DurationSegmentResource>
duration_segment_merge_nif([[maybe_unused]] ErlNifEnv *env,
                           int64_t edge_duration,
                           fine::ResourcePtr<DurationSegmentResource> first,
                           fine::ResourcePtr<DurationSegmentResource> second)
{
    DurationSegment merged = DurationSegment::merge(
        Duration{edge_duration}, first->segment, second->segment);
    return fine::make_resource<DurationSegmentResource>(merged);
}

FINE_NIF(duration_segment_merge_nif, 0);

// Get the duration
int64_t
duration_segment_duration_nif([[maybe_unused]] ErlNifEnv *env,
                              fine::ResourcePtr<DurationSegmentResource> seg)
{
    return static_cast<int64_t>(seg->segment.duration());
}

FINE_NIF(duration_segment_duration_nif, 0);

// Get the time warp (optionally with max_duration constraint)
int64_t
duration_segment_time_warp_nif([[maybe_unused]] ErlNifEnv *env,
                               fine::ResourcePtr<DurationSegmentResource> seg,
                               int64_t max_duration)
{
    return static_cast<int64_t>(seg->segment.timeWarp(Duration{max_duration}));
}

FINE_NIF(duration_segment_time_warp_nif, 0);

// Get start_early
int64_t
duration_segment_start_early_nif([[maybe_unused]] ErlNifEnv *env,
                                 fine::ResourcePtr<DurationSegmentResource> seg)
{
    return static_cast<int64_t>(seg->segment.startEarly());
}

FINE_NIF(duration_segment_start_early_nif, 0);

// Get start_late
int64_t
duration_segment_start_late_nif([[maybe_unused]] ErlNifEnv *env,
                                fine::ResourcePtr<DurationSegmentResource> seg)
{
    return static_cast<int64_t>(seg->segment.startLate());
}

FINE_NIF(duration_segment_start_late_nif, 0);

// Get end_early
int64_t
duration_segment_end_early_nif([[maybe_unused]] ErlNifEnv *env,
                               fine::ResourcePtr<DurationSegmentResource> seg)
{
    return static_cast<int64_t>(seg->segment.endEarly());
}

FINE_NIF(duration_segment_end_early_nif, 0);

// Get end_late
int64_t
duration_segment_end_late_nif([[maybe_unused]] ErlNifEnv *env,
                              fine::ResourcePtr<DurationSegmentResource> seg)
{
    return static_cast<int64_t>(seg->segment.endLate());
}

FINE_NIF(duration_segment_end_late_nif, 0);

// Get prev_end_late
int64_t duration_segment_prev_end_late_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DurationSegmentResource> seg)
{
    return static_cast<int64_t>(seg->segment.prevEndLate());
}

FINE_NIF(duration_segment_prev_end_late_nif, 0);

// Get release_time
int64_t duration_segment_release_time_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DurationSegmentResource> seg)
{
    return static_cast<int64_t>(seg->segment.releaseTime());
}

FINE_NIF(duration_segment_release_time_nif, 0);

// Get slack
int64_t
duration_segment_slack_nif([[maybe_unused]] ErlNifEnv *env,
                           fine::ResourcePtr<DurationSegmentResource> seg)
{
    return static_cast<int64_t>(seg->segment.slack());
}

FINE_NIF(duration_segment_slack_nif, 0);

// Finalise at the back - returns new segment
fine::ResourcePtr<DurationSegmentResource> duration_segment_finalise_back_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DurationSegmentResource> seg)
{
    DurationSegment finalised = seg->segment.finaliseBack();
    return fine::make_resource<DurationSegmentResource>(finalised);
}

FINE_NIF(duration_segment_finalise_back_nif, 0);

// Finalise at the front - returns new segment
fine::ResourcePtr<DurationSegmentResource> duration_segment_finalise_front_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<DurationSegmentResource> seg)
{
    DurationSegment finalised = seg->segment.finaliseFront();
    return fine::make_resource<DurationSegmentResource>(finalised);
}

FINE_NIF(duration_segment_finalise_front_nif, 0);

// -----------------------------------------------------------------------------
// LoadSegment NIFs
// -----------------------------------------------------------------------------

// Create a LoadSegment from raw parameters
fine::ResourcePtr<LoadSegmentResource>
create_load_segment_nif([[maybe_unused]] ErlNifEnv *env,
                        int64_t delivery,
                        int64_t pickup,
                        int64_t load,
                        int64_t excess_load)
{
    LoadSegment seg{
        Load{delivery}, Load{pickup}, Load{load}, Load{excess_load}};
    return fine::make_resource<LoadSegmentResource>(seg);
}

FINE_NIF(create_load_segment_nif, 0);

// Static merge of two segments
fine::ResourcePtr<LoadSegmentResource>
load_segment_merge_nif([[maybe_unused]] ErlNifEnv *env,
                       fine::ResourcePtr<LoadSegmentResource> first,
                       fine::ResourcePtr<LoadSegmentResource> second)
{
    LoadSegment merged = LoadSegment::merge(first->segment, second->segment);
    return fine::make_resource<LoadSegmentResource>(merged);
}

FINE_NIF(load_segment_merge_nif, 0);

// Finalise the segment with a capacity
fine::ResourcePtr<LoadSegmentResource>
load_segment_finalise_nif([[maybe_unused]] ErlNifEnv *env,
                          fine::ResourcePtr<LoadSegmentResource> seg,
                          int64_t capacity)
{
    LoadSegment finalised = seg->segment.finalise(Load{capacity});
    return fine::make_resource<LoadSegmentResource>(finalised);
}

FINE_NIF(load_segment_finalise_nif, 0);

// Get delivery amount
int64_t load_segment_delivery_nif([[maybe_unused]] ErlNifEnv *env,
                                  fine::ResourcePtr<LoadSegmentResource> seg)
{
    return static_cast<int64_t>(seg->segment.delivery());
}

FINE_NIF(load_segment_delivery_nif, 0);

// Get pickup amount
int64_t load_segment_pickup_nif([[maybe_unused]] ErlNifEnv *env,
                                fine::ResourcePtr<LoadSegmentResource> seg)
{
    return static_cast<int64_t>(seg->segment.pickup());
}

FINE_NIF(load_segment_pickup_nif, 0);

// Get load
int64_t load_segment_load_nif([[maybe_unused]] ErlNifEnv *env,
                              fine::ResourcePtr<LoadSegmentResource> seg)
{
    return static_cast<int64_t>(seg->segment.load());
}

FINE_NIF(load_segment_load_nif, 0);

// Get excess load with capacity constraint
int64_t load_segment_excess_load_nif([[maybe_unused]] ErlNifEnv *env,
                                     fine::ResourcePtr<LoadSegmentResource> seg,
                                     int64_t capacity)
{
    return static_cast<int64_t>(seg->segment.excessLoad(Load{capacity}));
}

FINE_NIF(load_segment_excess_load_nif, 0);

// -----------------------------------------------------------------------------
// PerturbationManager NIFs
// -----------------------------------------------------------------------------

struct PerturbationManagerResource
{
    pyvrp::search::PerturbationParams params;
    pyvrp::search::PerturbationManager manager;

    PerturbationManagerResource(size_t min_perturbations,
                                size_t max_perturbations)
        : params(min_perturbations, max_perturbations), manager(params)
    {
    }
};

FINE_RESOURCE(PerturbationManagerResource);

// Create a PerturbationManager with given params
fine::ResourcePtr<PerturbationManagerResource>
create_perturbation_manager_nif([[maybe_unused]] ErlNifEnv *env,
                                int64_t min_perturbations,
                                int64_t max_perturbations)
{
    if (min_perturbations > max_perturbations)
    {
        throw std::invalid_argument(
            "min_perturbations must be <= max_perturbations.");
    }
    return fine::make_resource<PerturbationManagerResource>(
        static_cast<size_t>(min_perturbations),
        static_cast<size_t>(max_perturbations));
}

FINE_NIF(create_perturbation_manager_nif, 0);

// Get min_perturbations
int64_t perturbation_manager_min_perturbations_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<PerturbationManagerResource> pm)
{
    return static_cast<int64_t>(pm->params.minPerturbations);
}

FINE_NIF(perturbation_manager_min_perturbations_nif, 0);

// Get max_perturbations
int64_t perturbation_manager_max_perturbations_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<PerturbationManagerResource> pm)
{
    return static_cast<int64_t>(pm->params.maxPerturbations);
}

FINE_NIF(perturbation_manager_max_perturbations_nif, 0);

// Get num_perturbations
int64_t perturbation_manager_num_perturbations_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<PerturbationManagerResource> pm)
{
    return static_cast<int64_t>(pm->manager.numPerturbations());
}

FINE_NIF(perturbation_manager_num_perturbations_nif, 0);

// Shuffle to pick a new random number of perturbations
fine::ResourcePtr<PerturbationManagerResource> perturbation_manager_shuffle_nif(
    [[maybe_unused]] ErlNifEnv *env,
    fine::ResourcePtr<PerturbationManagerResource> pm,
    fine::ResourcePtr<RNGResource> rng)
{
    pm->manager.shuffle(rng->rng);
    return pm;
}

FINE_NIF(perturbation_manager_shuffle_nif, 0);

// -----------------------------------------------------------------------------
// Helper Function Implementations
// -----------------------------------------------------------------------------

// Get a number (double or int) as double
static bool get_number_as_double([[maybe_unused]] ErlNifEnv *env,
                                 ERL_NIF_TERM term,
                                 double *out)
{
    if (enif_get_double(env, term, out))
    {
        return true;
    }
    int64_t int_val;
    if (enif_get_int64(env, term, &int_val))
    {
        *out = static_cast<double>(int_val);
        return true;
    }
    return false;
}

// Prepare node for transfer to a new route.
// Must be called BEFORE adding node to new route.
// Returns true if ownership transfer from old route is needed.
static bool
prepare_node_transfer(fine::ResourcePtr<SearchRouteResource> &route_resource,
                      fine::ResourcePtr<SearchNodeResource> &node_resource)
{
    auto *target_data = route_resource->data.get();

    if (node_resource->owned)
    {
        // Standalone node - will transfer ownership after add
        return false;
    }

    if (node_resource->parentRoute
        && node_resource->parentRoute.get() != target_data)
    {
        // Node is from a different route - remove from old route first
        auto *old_route = node_resource->parentRoute->route.get();
        if (old_route && node_resource->node->route() == old_route)
        {
            old_route->remove(node_resource->node->idx());
        }
        return true;  // Ownership transfer needed
    }

    return false;  // Already in this route or no parent
}

// Complete node ownership transfer after adding to route.
static void
complete_node_transfer(fine::ResourcePtr<SearchRouteResource> &route_resource,
                       fine::ResourcePtr<SearchNodeResource> &node_resource,
                       bool transfer_from_old_route)
{
    if (node_resource->owned)
    {
        // Standalone node - transfer ownership to route
        route_resource->ownedNodes().push_back(
            std::unique_ptr<search::Route::Node>(node_resource->node));
        node_resource->owned = false;
    }
    else if (transfer_from_old_route && node_resource->parentRoute)
    {
        // Move ownership from old route's ownedNodes to new
        auto &old_nodes = node_resource->parentRoute->ownedNodes;
        for (auto it = old_nodes.begin(); it != old_nodes.end(); ++it)
        {
            if (it->get() == node_resource->node)
            {
                route_resource->ownedNodes().push_back(std::move(*it));
                old_nodes.erase(it);
                break;
            }
        }
    }

    // Update parent reference
    node_resource->parentRoute = route_resource->data;
}

// Core implementation for reconciling node ownership after route operations.
// After PyVRP operations move nodes between routes, this ensures our ownedNodes
// vectors match what's actually in each route's PyVRP node list.
static void reconcile_route_ownership_impl(
    search::Route *route1,
    search::Route *route2,
    std::vector<std::unique_ptr<search::Route::Node>> &owned1,
    std::vector<std::unique_ptr<search::Route::Node>> &owned2)
{
    // Build sets of which nodes are in which PyVRP route (excluding depots)
    std::set<search::Route::Node *> in_route1, in_route2;
    for (size_t i = 1; i < route1->size() - 1; ++i)
    {
        auto *node = (*route1)[i];
        if (!node->isDepot())
        {
            in_route1.insert(node);
        }
    }
    for (size_t i = 1; i < route2->size() - 1; ++i)
    {
        auto *node = (*route2)[i];
        if (!node->isDepot())
        {
            in_route2.insert(node);
        }
    }

    // Find and collect nodes that need to move between ownership vectors
    std::vector<std::unique_ptr<search::Route::Node>> to_move_to_2;
    for (auto it = owned1.begin(); it != owned1.end();)
    {
        if (in_route2.count(it->get()) > 0)
        {
            to_move_to_2.push_back(std::move(*it));
            it = owned1.erase(it);
        }
        else
        {
            ++it;
        }
    }

    std::vector<std::unique_ptr<search::Route::Node>> to_move_to_1;
    for (auto it = owned2.begin(); it != owned2.end();)
    {
        if (in_route1.count(it->get()) > 0)
        {
            to_move_to_1.push_back(std::move(*it));
            it = owned2.erase(it);
        }
        else
        {
            ++it;
        }
    }

    // Transfer ownership
    for (auto &node : to_move_to_2)
    {
        owned2.push_back(std::move(node));
    }
    for (auto &node : to_move_to_1)
    {
        owned1.push_back(std::move(node));
    }
}

// Overload for route-based operations (SwapStar, SwapRoutes)
static void reconcile_route_ownership(
    fine::ResourcePtr<SearchRouteResource> &route1_resource,
    fine::ResourcePtr<SearchRouteResource> &route2_resource)
{
    reconcile_route_ownership_impl(route1_resource->route(),
                                   route2_resource->route(),
                                   route1_resource->ownedNodes(),
                                   route2_resource->ownedNodes());
}

// Overload for node-based operations (Exchange, SwapTails)
static void
reconcile_route_ownership(std::shared_ptr<SearchRouteData> &route1_data,
                          std::shared_ptr<SearchRouteData> &route2_data)
{
    if (!route1_data || !route2_data)
        return;
    reconcile_route_ownership_impl(route1_data->route.get(),
                                   route2_data->route.get(),
                                   route1_data->ownedNodes,
                                   route2_data->ownedNodes);
}

// -----------------------------------------------------------------------------
// Module Initialization
// -----------------------------------------------------------------------------

FINE_INIT("Elixir.ExVrp.Native");

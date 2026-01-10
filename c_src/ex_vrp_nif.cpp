/**
 * ExVrp NIF - Elixir bindings for PyVRP C++ core
 *
 * Uses the Fine library for ergonomic C++ to Elixir interop.
 */

#include <fine.hpp>

#include "pyvrp/ProblemData.h"
#include "pyvrp/Solution.h"
#include "pyvrp/CostEvaluator.h"
#include "pyvrp/RandomNumberGenerator.h"
#include "pyvrp/search/LocalSearch.h"
#include "pyvrp/search/Exchange.h"
#include "pyvrp/search/SwapStar.h"
#include "pyvrp/search/SwapTails.h"
#include "pyvrp/search/SwapRoutes.h"
#include "pyvrp/search/RelocateWithDepot.h"
#include "pyvrp/search/PerturbationManager.h"

#include <vector>
#include <string>
#include <optional>
#include <cstdint>
#include <cmath>
#include <limits>

using namespace pyvrp;

// -----------------------------------------------------------------------------
// Resource Types
// -----------------------------------------------------------------------------

// Wrap ProblemData in a shared_ptr for resource management
struct ProblemDataResource {
    std::shared_ptr<ProblemData> data;

    explicit ProblemDataResource(std::shared_ptr<ProblemData> d) : data(std::move(d)) {}
};

// Wrap Solution for resource management
struct SolutionResource {
    Solution solution;
    std::shared_ptr<ProblemData> problemData;  // Keep problem data alive

    SolutionResource(Solution s, std::shared_ptr<ProblemData> pd)
        : solution(std::move(s)), problemData(std::move(pd)) {}
};

// Wrap CostEvaluator for resource management
struct CostEvaluatorResource {
    CostEvaluator evaluator;

    CostEvaluatorResource(std::vector<double> loadPenalties, double twPenalty, double distPenalty)
        : evaluator(std::move(loadPenalties), twPenalty, distPenalty) {}
};

FINE_RESOURCE(ProblemDataResource);
FINE_RESOURCE(SolutionResource);
FINE_RESOURCE(CostEvaluatorResource);

// -----------------------------------------------------------------------------
// Helper: Decode Elixir structs to C++ types
// -----------------------------------------------------------------------------

// Decode a single client from Elixir map
ProblemData::Client decode_client(ErlNifEnv* env, ERL_NIF_TERM term) {
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

    if (!enif_map_iterator_create(env, term, &iter, ERL_NIF_MAP_ITERATOR_FIRST)) {
        throw std::runtime_error("Expected map for client");
    }

    while (enif_map_iterator_get_pair(env, &iter, &key, &value)) {
        char atom_buf[256];
        if (enif_get_atom(env, key, atom_buf, sizeof(atom_buf), ERL_NIF_LATIN1)) {
            std::string key_str(atom_buf);

            if (key_str == "x") {
                enif_get_int64(env, value, &x);
            } else if (key_str == "y") {
                enif_get_int64(env, value, &y);
            } else if (key_str == "delivery") {
                // Decode list of integers
                unsigned len;
                if (enif_get_list_length(env, value, &len)) {
                    delivery_vec.resize(len);
                    ERL_NIF_TERM head, tail = value;
                    for (unsigned i = 0; i < len; i++) {
                        enif_get_list_cell(env, tail, &head, &tail);
                        int64_t v;
                        enif_get_int64(env, head, &v);
                        delivery_vec[i] = v;
                    }
                }
            } else if (key_str == "pickup") {
                unsigned len;
                if (enif_get_list_length(env, value, &len)) {
                    pickup_vec.resize(len);
                    ERL_NIF_TERM head, tail = value;
                    for (unsigned i = 0; i < len; i++) {
                        enif_get_list_cell(env, tail, &head, &tail);
                        int64_t v;
                        enif_get_int64(env, head, &v);
                        pickup_vec[i] = v;
                    }
                }
            } else if (key_str == "service_duration") {
                enif_get_int64(env, value, &service_duration);
            } else if (key_str == "tw_early") {
                enif_get_int64(env, value, &tw_early);
            } else if (key_str == "tw_late") {
                // Check for :infinity atom
                char buf[32];
                if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1)) {
                    if (std::string(buf) == "infinity") {
                        tw_late = std::numeric_limits<int64_t>::max();
                    }
                } else {
                    enif_get_int64(env, value, &tw_late);
                }
            } else if (key_str == "release_time") {
                enif_get_int64(env, value, &release_time);
            } else if (key_str == "prize") {
                enif_get_int64(env, value, &prize);
            } else if (key_str == "required") {
                char buf[32];
                if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1)) {
                    required = (std::string(buf) == "true");
                }
            } else if (key_str == "group") {
                // Check for nil
                char buf[32];
                if (!enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1) ||
                    std::string(buf) != "nil") {
                    int64_t g;
                    if (enif_get_int64(env, value, &g)) {
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
    for (auto d : delivery_vec) delivery_loads.push_back(Load(d));
    for (auto p : pickup_vec) pickup_loads.push_back(Load(p));

    // If empty, use defaults
    if (delivery_loads.empty()) delivery_loads.push_back(Load(0));
    if (pickup_loads.empty()) pickup_loads.push_back(Load(0));

    return ProblemData::Client(
        Coordinate(x),
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
ProblemData::Depot decode_depot(ErlNifEnv* env, ERL_NIF_TERM term) {
    int64_t x = 0, y = 0;

    ERL_NIF_TERM key, value;
    ErlNifMapIterator iter;

    if (!enif_map_iterator_create(env, term, &iter, ERL_NIF_MAP_ITERATOR_FIRST)) {
        throw std::runtime_error("Expected map for depot");
    }

    while (enif_map_iterator_get_pair(env, &iter, &key, &value)) {
        char atom_buf[256];
        if (enif_get_atom(env, key, atom_buf, sizeof(atom_buf), ERL_NIF_LATIN1)) {
            std::string key_str(atom_buf);

            if (key_str == "x") {
                enif_get_int64(env, value, &x);
            } else if (key_str == "y") {
                enif_get_int64(env, value, &y);
            }
        }
        enif_map_iterator_next(env, &iter);
    }
    enif_map_iterator_destroy(env, &iter);

    return ProblemData::Depot(Coordinate(x), Coordinate(y), Duration(0),
                               std::numeric_limits<Duration>::max(), std::string(""));
}

// Decode a single vehicle type from Elixir map
ProblemData::VehicleType decode_vehicle_type(ErlNifEnv* env, ERL_NIF_TERM term, size_t num_dims) {
    int64_t num_available = 1;
    std::vector<int64_t> capacity_vec;
    int64_t start_depot = 0;
    int64_t end_depot = 0;
    int64_t fixed_cost = 0;
    int64_t tw_early = 0;
    int64_t tw_late = std::numeric_limits<int64_t>::max();
    int64_t max_duration = std::numeric_limits<int64_t>::max();
    int64_t max_distance = std::numeric_limits<int64_t>::max();
    int64_t unit_distance_cost = 1;
    int64_t unit_duration_cost = 0;
    int64_t profile = 0;

    ERL_NIF_TERM key, value;
    ErlNifMapIterator iter;

    if (!enif_map_iterator_create(env, term, &iter, ERL_NIF_MAP_ITERATOR_FIRST)) {
        throw std::runtime_error("Expected map for vehicle_type");
    }

    while (enif_map_iterator_get_pair(env, &iter, &key, &value)) {
        char atom_buf[256];
        if (enif_get_atom(env, key, atom_buf, sizeof(atom_buf), ERL_NIF_LATIN1)) {
            std::string key_str(atom_buf);

            if (key_str == "num_available") {
                enif_get_int64(env, value, &num_available);
            } else if (key_str == "capacity") {
                // Handle list or single value
                unsigned len;
                if (enif_get_list_length(env, value, &len)) {
                    capacity_vec.resize(len);
                    ERL_NIF_TERM head, tail = value;
                    for (unsigned i = 0; i < len; i++) {
                        enif_get_list_cell(env, tail, &head, &tail);
                        int64_t v;
                        enif_get_int64(env, head, &v);
                        capacity_vec[i] = v;
                    }
                }
            } else if (key_str == "start_depot") {
                enif_get_int64(env, value, &start_depot);
            } else if (key_str == "end_depot") {
                enif_get_int64(env, value, &end_depot);
            } else if (key_str == "fixed_cost") {
                enif_get_int64(env, value, &fixed_cost);
            } else if (key_str == "tw_early") {
                enif_get_int64(env, value, &tw_early);
            } else if (key_str == "tw_late" || key_str == "shift_duration") {
                char buf[32];
                if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1)) {
                    if (std::string(buf) == "infinity") {
                        tw_late = std::numeric_limits<int64_t>::max();
                    }
                } else {
                    enif_get_int64(env, value, &tw_late);
                }
            } else if (key_str == "max_distance") {
                char buf[32];
                if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1)) {
                    if (std::string(buf) == "infinity") {
                        max_distance = std::numeric_limits<int64_t>::max();
                    }
                } else {
                    enif_get_int64(env, value, &max_distance);
                }
            } else if (key_str == "unit_distance_cost") {
                enif_get_int64(env, value, &unit_distance_cost);
            } else if (key_str == "unit_duration_cost") {
                enif_get_int64(env, value, &unit_duration_cost);
            }
        }
        enif_map_iterator_next(env, &iter);
    }
    enif_map_iterator_destroy(env, &iter);

    // Convert capacity to vector<Load>
    std::vector<Load> capacity_loads;
    for (auto c : capacity_vec) capacity_loads.push_back(Load(c));

    // Ensure capacity has the right number of dimensions
    while (capacity_loads.size() < num_dims) {
        capacity_loads.push_back(Load(0));
    }

    return ProblemData::VehicleType(
        static_cast<size_t>(num_available),
        std::move(capacity_loads),
        static_cast<size_t>(start_depot),
        static_cast<size_t>(end_depot),
        Cost(fixed_cost),
        Duration(tw_early),
        Duration(tw_late),
        Duration(max_duration),  // shiftDuration
        Distance(max_distance),
        Cost(unit_distance_cost),
        Cost(unit_duration_cost),
        static_cast<size_t>(profile),
        std::nullopt,  // startLate
        std::vector<Load>{},  // initialLoad
        std::vector<size_t>{},  // reloadDepots
        std::numeric_limits<size_t>::max(),  // maxReloads
        Duration(0),  // maxOvertime
        Cost(0),  // unitOvertimeCost
        std::string("")  // name
    );
}

// Decode distance/duration matrix from nested list
Matrix<Distance> decode_distance_matrix(ErlNifEnv* env, ERL_NIF_TERM term) {
    unsigned num_rows;
    if (!enif_get_list_length(env, term, &num_rows) || num_rows == 0) {
        return Matrix<Distance>();
    }

    // Get first row to determine columns
    ERL_NIF_TERM head, tail = term;
    enif_get_list_cell(env, tail, &head, &tail);

    unsigned num_cols;
    if (!enif_get_list_length(env, head, &num_cols) || num_cols == 0) {
        return Matrix<Distance>();
    }

    std::vector<Distance> data;
    data.reserve(num_rows * num_cols);

    // Reset to beginning
    tail = term;
    for (unsigned r = 0; r < num_rows; r++) {
        enif_get_list_cell(env, tail, &head, &tail);

        ERL_NIF_TERM cell_head, cell_tail = head;
        for (unsigned c = 0; c < num_cols; c++) {
            enif_get_list_cell(env, cell_tail, &cell_head, &cell_tail);
            int64_t val;
            enif_get_int64(env, cell_head, &val);
            data.push_back(Distance(val));
        }
    }

    return Matrix<Distance>(std::move(data), num_rows, num_cols);
}

Matrix<Duration> decode_duration_matrix(ErlNifEnv* env, ERL_NIF_TERM term) {
    unsigned num_rows;
    if (!enif_get_list_length(env, term, &num_rows) || num_rows == 0) {
        return Matrix<Duration>();
    }

    ERL_NIF_TERM head, tail = term;
    enif_get_list_cell(env, tail, &head, &tail);

    unsigned num_cols;
    if (!enif_get_list_length(env, head, &num_cols) || num_cols == 0) {
        return Matrix<Duration>();
    }

    std::vector<Duration> data;
    data.reserve(num_rows * num_cols);

    tail = term;
    for (unsigned r = 0; r < num_rows; r++) {
        enif_get_list_cell(env, tail, &head, &tail);

        ERL_NIF_TERM cell_head, cell_tail = head;
        for (unsigned c = 0; c < num_cols; c++) {
            enif_get_list_cell(env, cell_tail, &cell_head, &cell_tail);
            int64_t val;
            enif_get_int64(env, cell_head, &val);
            data.push_back(Duration(val));
        }
    }

    return Matrix<Duration>(std::move(data), num_rows, num_cols);
}

// Calculate Euclidean distance between two points
int64_t euclidean_distance(int64_t x1, int64_t y1, int64_t x2, int64_t y2) {
    double dx = static_cast<double>(x2 - x1);
    double dy = static_cast<double>(y2 - y1);
    return static_cast<int64_t>(std::round(std::sqrt(dx * dx + dy * dy)));
}

// -----------------------------------------------------------------------------
// NIF Functions
// -----------------------------------------------------------------------------

/**
 * Create ProblemData from Elixir Model struct.
 */
fine::Ok<fine::ResourcePtr<ProblemDataResource>> create_problem_data(
    ErlNifEnv* env,
    fine::Term model_term)
{
    // Decode the model map
    ERL_NIF_TERM clients_term, depots_term, vehicle_types_term;
    ERL_NIF_TERM distance_matrices_term, duration_matrices_term;

    ERL_NIF_TERM key;

    // Get clients
    key = enif_make_atom(env, "clients");
    if (!enif_get_map_value(env, model_term, key, &clients_term)) {
        throw std::runtime_error("Model missing clients field");
    }

    // Get depots
    key = enif_make_atom(env, "depots");
    if (!enif_get_map_value(env, model_term, key, &depots_term)) {
        throw std::runtime_error("Model missing depots field");
    }

    // Get vehicle types
    key = enif_make_atom(env, "vehicle_types");
    if (!enif_get_map_value(env, model_term, key, &vehicle_types_term)) {
        throw std::runtime_error("Model missing vehicle_types field");
    }

    // Get distance matrices (optional)
    key = enif_make_atom(env, "distance_matrices");
    bool has_dist_matrices = enif_get_map_value(env, model_term, key, &distance_matrices_term);

    // Get duration matrices (optional)
    key = enif_make_atom(env, "duration_matrices");
    bool has_dur_matrices = enif_get_map_value(env, model_term, key, &duration_matrices_term);

    // Decode depots
    std::vector<ProblemData::Depot> depots;
    unsigned depots_len;
    enif_get_list_length(env, depots_term, &depots_len);
    depots.reserve(depots_len);

    ERL_NIF_TERM head, tail = depots_term;
    for (unsigned i = 0; i < depots_len; i++) {
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
    for (unsigned i = 0; i < clients_len; i++) {
        enif_get_list_cell(env, tail, &head, &tail);
        auto client = decode_client(env, head);
        if (i == 0) {
            // Use first client's delivery dimension count as reference
            // (PyVRP requires consistent dimensions)
        }
        clients.push_back(std::move(client));
    }

    if (!clients.empty()) {
        num_dims = clients[0].delivery.size();
    }

    // Decode vehicle types
    std::vector<ProblemData::VehicleType> vehicle_types;
    unsigned vt_len;
    enif_get_list_length(env, vehicle_types_term, &vt_len);
    vehicle_types.reserve(vt_len);

    tail = vehicle_types_term;
    for (unsigned i = 0; i < vt_len; i++) {
        enif_get_list_cell(env, tail, &head, &tail);
        vehicle_types.push_back(decode_vehicle_type(env, head, num_dims));
    }

    // Create matrices
    size_t num_locations = depots.size() + clients.size();
    std::vector<Matrix<Distance>> dist_matrices;
    std::vector<Matrix<Duration>> dur_matrices;

    if (has_dist_matrices) {
        unsigned dm_len;
        enif_get_list_length(env, distance_matrices_term, &dm_len);
        if (dm_len > 0) {
            tail = distance_matrices_term;
            for (unsigned i = 0; i < dm_len; i++) {
                enif_get_list_cell(env, tail, &head, &tail);
                dist_matrices.push_back(decode_distance_matrix(env, head));
            }
        }
    }

    if (has_dur_matrices) {
        unsigned dm_len;
        enif_get_list_length(env, duration_matrices_term, &dm_len);
        if (dm_len > 0) {
            tail = duration_matrices_term;
            for (unsigned i = 0; i < dm_len; i++) {
                enif_get_list_cell(env, tail, &head, &tail);
                dur_matrices.push_back(decode_duration_matrix(env, head));
            }
        }
    }

    // If no matrices provided, generate from coordinates
    if (dist_matrices.empty()) {
        Matrix<Distance> dist_mat(num_locations, num_locations);
        Matrix<Duration> dur_mat(num_locations, num_locations);

        // Helper to get coordinates
        auto get_coords = [&](size_t idx) -> std::pair<int64_t, int64_t> {
            if (idx < depots.size()) {
                return {static_cast<int64_t>(depots[idx].x), static_cast<int64_t>(depots[idx].y)};
            } else {
                auto& c = clients[idx - depots.size()];
                return {static_cast<int64_t>(c.x), static_cast<int64_t>(c.y)};
            }
        };

        for (size_t i = 0; i < num_locations; i++) {
            auto [x1, y1] = get_coords(i);
            for (size_t j = 0; j < num_locations; j++) {
                auto [x2, y2] = get_coords(j);
                int64_t dist = euclidean_distance(x1, y1, x2, y2);
                dist_mat(i, j) = Distance(dist);
                dur_mat(i, j) = Duration(dist);  // Assume unit speed
            }
        }

        dist_matrices.push_back(std::move(dist_mat));
        dur_matrices.push_back(std::move(dur_mat));
    }

    // Create ProblemData
    auto problem_data = std::make_shared<ProblemData>(
        std::move(clients),
        std::move(depots),
        std::move(vehicle_types),
        std::move(dist_matrices),
        std::move(dur_matrices)
    );

    return fine::Ok(fine::make_resource<ProblemDataResource>(problem_data));
}

FINE_NIF(create_problem_data, 0);

/**
 * Solve the VRP problem - creates random solution and runs basic local search.
 */
fine::Ok<fine::ResourcePtr<SolutionResource>> solve(
    ErlNifEnv* env,
    fine::ResourcePtr<ProblemDataResource> problem_resource,
    fine::Term opts_term)
{
    auto& problem_data = problem_resource->data;

    // Parse options
    int64_t seed = 42;

    ERL_NIF_TERM key, value;

    key = enif_make_atom(env, "seed");
    if (enif_get_map_value(env, opts_term, key, &value)) {
        enif_get_int64(env, value, &seed);
    }

    // Create RNG
    RandomNumberGenerator rng(static_cast<uint32_t>(seed));

    // Create initial random solution
    Solution solution(*problem_data, rng);

    // For now, just return the random solution
    // TODO: Implement proper local search once we understand the full API

    return fine::Ok(fine::make_resource<SolutionResource>(std::move(solution), problem_data));
}

FINE_NIF(solve, ERL_NIF_DIRTY_JOB_CPU_BOUND);

/**
 * Get solution total distance.
 */
int64_t solution_distance(
    [[maybe_unused]] ErlNifEnv* env,
    fine::ResourcePtr<SolutionResource> solution_resource)
{
    return static_cast<int64_t>(solution_resource->solution.distance());
}

FINE_NIF(solution_distance, 0);

/**
 * Get solution total duration.
 */
int64_t solution_duration(
    [[maybe_unused]] ErlNifEnv* env,
    fine::ResourcePtr<SolutionResource> solution_resource)
{
    return static_cast<int64_t>(solution_resource->solution.duration());
}

FINE_NIF(solution_duration, 0);

/**
 * Check if solution is feasible.
 */
bool solution_is_feasible(
    [[maybe_unused]] ErlNifEnv* env,
    fine::ResourcePtr<SolutionResource> solution_resource)
{
    return solution_resource->solution.isFeasible();
}

FINE_NIF(solution_is_feasible, 0);

/**
 * Check if solution is complete.
 */
bool solution_is_complete(
    [[maybe_unused]] ErlNifEnv* env,
    fine::ResourcePtr<SolutionResource> solution_resource)
{
    return solution_resource->solution.isComplete();
}

FINE_NIF(solution_is_complete, 0);

/**
 * Get number of routes in solution.
 */
int64_t solution_num_routes(
    [[maybe_unused]] ErlNifEnv* env,
    fine::ResourcePtr<SolutionResource> solution_resource)
{
    return static_cast<int64_t>(solution_resource->solution.numRoutes());
}

FINE_NIF(solution_num_routes, 0);

/**
 * Get number of clients in solution.
 */
int64_t solution_num_clients(
    [[maybe_unused]] ErlNifEnv* env,
    fine::ResourcePtr<SolutionResource> solution_resource)
{
    return static_cast<int64_t>(solution_resource->solution.numClients());
}

FINE_NIF(solution_num_clients, 0);

/**
 * Get routes from solution as list of client index lists.
 */
fine::Term solution_routes(
    ErlNifEnv* env,
    fine::ResourcePtr<SolutionResource> solution_resource)
{
    auto& solution = solution_resource->solution;

    auto const& routes = solution.routes();
    std::vector<ERL_NIF_TERM> route_terms;
    route_terms.reserve(routes.size());

    for (auto const& route : routes) {
        std::vector<ERL_NIF_TERM> client_terms;

        for (auto const& visit : route.visits()) {
            // visits() returns client indices (already 0-based, relative to clients)
            client_terms.push_back(enif_make_int64(env, static_cast<int64_t>(visit)));
        }

        route_terms.push_back(enif_make_list_from_array(env,
            client_terms.data(), client_terms.size()));
    }

    return fine::Term(enif_make_list_from_array(env, route_terms.data(), route_terms.size()));
}

FINE_NIF(solution_routes, 0);

// -----------------------------------------------------------------------------
// CostEvaluator
// -----------------------------------------------------------------------------

/**
 * Create a CostEvaluator from options (map).
 */
fine::Ok<fine::ResourcePtr<CostEvaluatorResource>> create_cost_evaluator_nif(
    ErlNifEnv* env,
    fine::Term opts_term)
{
    std::vector<double> load_penalties;
    double tw_penalty = 1.0;
    double dist_penalty = 1.0;

    ERL_NIF_TERM key, value;

    // Get load_penalties
    key = enif_make_atom(env, "load_penalties");
    if (enif_get_map_value(env, opts_term, key, &value)) {
        unsigned len;
        if (enif_get_list_length(env, value, &len)) {
            load_penalties.reserve(len);
            ERL_NIF_TERM head, tail = value;
            for (unsigned i = 0; i < len; i++) {
                enif_get_list_cell(env, tail, &head, &tail);
                double v;
                enif_get_double(env, head, &v);
                load_penalties.push_back(v);
            }
        }
    }

    // Get tw_penalty
    key = enif_make_atom(env, "tw_penalty");
    if (enif_get_map_value(env, opts_term, key, &value)) {
        enif_get_double(env, value, &tw_penalty);
    }

    // Get dist_penalty
    key = enif_make_atom(env, "dist_penalty");
    if (enif_get_map_value(env, opts_term, key, &value)) {
        enif_get_double(env, value, &dist_penalty);
    }

    // Validate: penalties must be non-negative
    for (auto p : load_penalties) {
        if (p < 0) {
            throw std::runtime_error("Load penalties must be non-negative");
        }
    }
    if (tw_penalty < 0 || dist_penalty < 0) {
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
    [[maybe_unused]] ErlNifEnv* env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    return static_cast<int64_t>(
        evaluator_resource->evaluator.penalisedCost(solution_resource->solution));
}

FINE_NIF(solution_penalised_cost, 0);

/**
 * Compute cost of solution (max for infeasible).
 */
fine::Term solution_cost(
    ErlNifEnv* env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource)
{
    auto cost = evaluator_resource->evaluator.cost(solution_resource->solution);
    if (cost == std::numeric_limits<Cost>::max()) {
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
    ErlNifEnv* env,
    fine::ResourcePtr<ProblemDataResource> problem_resource,
    fine::Term opts_term)
{
    auto& problem_data = problem_resource->data;

    // Parse options
    int64_t seed = 42;

    ERL_NIF_TERM key, value;
    key = enif_make_atom(env, "seed");
    if (enif_get_map_value(env, opts_term, key, &value)) {
        enif_get_int64(env, value, &seed);
    }

    // Create RNG
    RandomNumberGenerator rng(static_cast<uint32_t>(seed));

    // Create random solution
    Solution solution(*problem_data, rng);

    return fine::Ok(fine::make_resource<SolutionResource>(std::move(solution), problem_data));
}

FINE_NIF(create_random_solution_nif, 0);

/**
 * Get the number of load dimensions from ProblemData.
 */
int64_t problem_data_num_load_dims(
    [[maybe_unused]] ErlNifEnv* env,
    fine::ResourcePtr<ProblemDataResource> problem_resource)
{
    return static_cast<int64_t>(problem_resource->data->numLoadDimensions());
}

FINE_NIF(problem_data_num_load_dims, 0);

// -----------------------------------------------------------------------------
// LocalSearch
// -----------------------------------------------------------------------------

/**
 * Build default neighbourhood for local search.
 */
pyvrp::search::SearchSpace::Neighbours build_neighbours(ProblemData const& data, size_t k = 40) {
    size_t const numLocs = data.numLocations();
    pyvrp::search::SearchSpace::Neighbours neighbours(numLocs);

    // Get distance matrix (use profile 0)
    auto const& distMatrix = data.distanceMatrix(0);

    // For each client, find k nearest clients
    for (size_t i = data.numDepots(); i < numLocs; ++i) {
        std::vector<std::pair<Distance, size_t>> distances;

        for (size_t j = data.numDepots(); j < numLocs; ++j) {
            if (i != j) {
                auto dist = distMatrix(i, j);
                distances.emplace_back(dist, j);
            }
        }

        // Sort by distance and take top k
        std::sort(distances.begin(), distances.end());

        for (size_t n = 0; n < std::min(k, distances.size()); ++n) {
            neighbours[i].push_back(distances[n].second);
        }
    }

    return neighbours;
}

/**
 * Perform local search on a solution.
 */
fine::Ok<fine::ResourcePtr<SolutionResource>> local_search_nif(
    ErlNifEnv* env,
    fine::ResourcePtr<SolutionResource> solution_resource,
    fine::ResourcePtr<ProblemDataResource> problem_resource,
    fine::ResourcePtr<CostEvaluatorResource> evaluator_resource,
    fine::Term opts_term)
{
    auto& problem_data = *problem_resource->data;
    auto& cost_evaluator = evaluator_resource->evaluator;

    // Parse options
    bool exhaustive = false;

    ERL_NIF_TERM key, value;
    key = enif_make_atom(env, "exhaustive");
    if (enif_get_map_value(env, opts_term, key, &value)) {
        char buf[32];
        if (enif_get_atom(env, value, buf, sizeof(buf), ERL_NIF_LATIN1)) {
            exhaustive = (std::string(buf) == "true");
        }
    }

    // Build neighbourhood
    auto neighbours = build_neighbours(problem_data);

    // Create perturbation manager with default params
    pyvrp::search::PerturbationParams perturbParams(1, 25);
    pyvrp::search::PerturbationManager perturbManager(perturbParams);

    // Create local search
    pyvrp::search::LocalSearch ls(problem_data, neighbours, perturbManager);

    // Add node operators (Exchange variants)
    pyvrp::search::Exchange<1, 0> relocate(problem_data);  // RELOCATE
    pyvrp::search::Exchange<2, 0> relocate2(problem_data); // 2-RELOCATE
    pyvrp::search::Exchange<1, 1> swap11(problem_data);    // SWAP(1,1)
    pyvrp::search::Exchange<2, 1> swap21(problem_data);    // SWAP(2,1)
    pyvrp::search::Exchange<2, 2> swap22(problem_data);    // SWAP(2,2)
    pyvrp::search::SwapTails swapTails(problem_data);      // SWAP-TAILS

    ls.addNodeOperator(relocate);
    ls.addNodeOperator(relocate2);
    ls.addNodeOperator(swap11);
    ls.addNodeOperator(swap21);
    ls.addNodeOperator(swap22);
    ls.addNodeOperator(swapTails);

    // Add route operators
    pyvrp::search::SwapStar swapStar(problem_data);
    pyvrp::search::SwapRoutes swapRoutes(problem_data);

    ls.addRouteOperator(swapStar);
    ls.addRouteOperator(swapRoutes);

    // Run local search
    Solution improved = ls(solution_resource->solution, cost_evaluator, exhaustive);

    return fine::Ok(fine::make_resource<SolutionResource>(
        std::move(improved), problem_resource->data));
}

FINE_NIF(local_search_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND);

// -----------------------------------------------------------------------------
// Module Initialization
// -----------------------------------------------------------------------------

FINE_INIT("Elixir.ExVrp.Native");

#include "main.h"
#include "monte_carlo_sampler.h"
#include "h5_support.h"
#include <tclap/CmdLine.h>
#include "deriv_engine.h"
#include "timing.h"
#include "thermostat.h"
#include <chrono>
#include <algorithm>
#include <set>
#include "random.h"
#include <random>
#include "state_logger.h"
#include <csignal>
#include <map>
#include <sstream>
#include <fstream>
#include <iostream>
#include <cstdlib>

#if defined(_OPENMP)
#include <omp.h>
#endif

using namespace std;
using namespace h5;

// If any stop signal is received (currently we trap sigterm and sigint)
// we increment any_stop_signal_received.
constexpr sig_atomic_t NO_SIGNAL = -1;  // FIXME is this a valid sentinel value?
volatile sig_atomic_t received_signal = NO_SIGNAL;

// if any stop signal is received, attempt to dump buffered state immediately.
// Perhaps I should also dump the exactly last position for each replica as
// well in case of an error, to aid debugging of say segfaults.  I need to be
// careful to stop each thread before draining the state to avoid race
// conditions.  This is all somewhat complicated, but worth it to have good
// stops no matter water.  I should also drain state in response to sigusr1 so
// that I can dump state before 100 frames if I need to while continuing the
// simulation.

static void abort_like_handler(int signal) {
    // NOTE TO THE INEXPERIENCED:
    //     This is a signal handler called in response to things like
    //     Ctrl-C.  These functions are very special, and there are very
    //     few things you are allowed to do in such a function without
    //     causing problems.  Basically, just set a global variable of type
    //     volatile sig_atomic_t and then notice the flag is set later in
    //     the code.  Even most forms of exiting the program are disallowed
    //     in a signal handler.  Please do not edit this function unless
    //     you have read extensively about signal handlers, especially for
    //     multithreaded code.

    // This signal handler is intended for signals that indicate the user
    // or OS wishes the program to terminate but after possibly writing any
    // remaining state.  There is some danger that a later SIGKILL could
    // corrupt the file being written to dump the last small amount of
    // state.  I think this is a risk worth taking.

    // Note that repeated Ctrl-C will not terminate the program if it is
    // still writing to the (possibly hanging) filesystem.  This is also
    // annoying, but the user can terminate with SIGKILL.

    received_signal = signal;
}

struct SignalHandlerHandler {
    // class to handle replacing signal handlers with orderly termination
    // If upside_main is used as a Python function, we must use RAII to
    // ensure than any termination will restore the Python signal handlers.
    typedef void (*signal_handler_t)(int);

    int signum;
    signal_handler_t old_handler;

    SignalHandlerHandler(int signum_, signal_handler_t handler):
        signum(signum_), old_handler(SIG_ERR)
    {
        // I will assume that I can use the standard signal system.  I am not 
        // sure how this will interact with Python, which can use sigaction.

        old_handler = signal(signum, handler);
        if(old_handler == SIG_ERR)
            fprintf(stderr, "Warning: problem installing signal handler."
                    " Does not affect correctness of simulation.\n");
    }

    virtual ~SignalHandlerHandler() {
        if(old_handler != SIG_ERR)
            if(signal(signum, old_handler) == SIG_ERR)
                fprintf(stderr, "Warning: problem restoring signal handler."
                    " Does not affect correctness of simulation.\n");
    }
};

    

struct System {
    int n_atom;
    uint32_t random_seed;
    float initial_temperature;
    float temperature;
    H5Obj config;
    H5Obj input;
    H5Obj output;
    shared_ptr<H5Logger> logger;
    DerivEngine engine;
    MultipleMonteCarloSampler mc_samplers;
    std::unique_ptr<device_buffer<float>> mom; // momentum
    OrnsteinUhlenbeckThermostat thermostat;
    uint64_t round_num;
    System(): round_num(0) {}

    void set_temperature(float new_temp) {
        temperature = new_temp;
        thermostat.set_temp(temperature);
    }
};


double stod_strict(const std::string& s) {
    size_t nchar = -1u;
    double x = stod(s, &nchar);
    if(nchar != s.size()) throw("invalid float '" + s + "'");
    return x;
}
int stoi_strict(const std::string& s) {
    size_t nchar = -1u;
    int i = stoi(s, &nchar);
    if(nchar != s.size()) throw("invalid integer '" + s + "'");
    return i;
}

vector<string> split_string(const string& src, const string& sep) {
    vector<string> ret;

    for(auto curr_pos = begin(src); curr_pos-begin(src) < ptrdiff_t(src.size()); ) {
        auto next_match_end = search(curr_pos, end(src), begin(sep), end(sep));
        ret.emplace_back(curr_pos, next_match_end);
        curr_pos = next_match_end + sep.size();
    }

    return ret;
}


struct ReplicaExchange {
    struct SwapPair {int sys1; int sys2; uint64_t n_attempt; uint64_t n_success; int set_id;};
    vector<vector<SwapPair>> swap_sets;
    vector<int> replica_indices;
    vector<vector<SwapPair*>> participating_swaps;
    int n_swap_sets;
    int n_attempt_swaps;

    ReplicaExchange(vector<System>& systems, vector<string> swap_sets_strings) {
        n_swap_sets = (int)swap_sets_strings.size();
        n_attempt_swaps = 0;
        int n_system = systems.size();
        for(int ns: range(n_system)) {
            replica_indices.push_back(ns);
            participating_swaps.emplace_back();
        }

        int set_id = 0;
        for(string& set_string: swap_sets_strings) {
            swap_sets.emplace_back();
            auto& set = swap_sets.back();
            
            for(auto pair_string: split_string(set_string,",")) {
                set.emplace_back();
                auto& s = set.back();
                auto p = split_string(pair_string, "-");
                if(p.size() != 2u) throw string("invalid swap pair, because it contains " +
                        to_string(p.size()) + "elements but should contain 2");

                s.sys1 = stoi_strict(p[0]);
                s.sys2 = stoi_strict(p[1]);

                s.n_attempt = 0u;
                s.n_success = 0u;
   
                s.set_id = set_id;

                int n_system = systems.size();
                if(s.sys1 >= n_system || s.sys2 >= n_system) throw string("invalid system");
            }

            set_id += 1;
        }

        for(auto& ss: swap_sets) {
            set<int> systems_in_set;
            for(auto& sw: ss) {
                if(systems_in_set.count(sw.sys1) ||
                   systems_in_set.count(sw.sys2) ||
                   sw.sys1==sw.sys2) {
                    throw string("Overlapping indices in swap set.  "
                            "No replica index can appear more than once in a swap set.  "
                            "You probably (but maybe not; I didn't look that closely) need more "
                            "swap sets to get non-overlapping pairs.");
                }
                systems_in_set.insert(sw.sys1);
                systems_in_set.insert(sw.sys2);

                participating_swaps[sw.sys1].push_back(&sw);
                participating_swaps[sw.sys2].push_back(&sw);
            }
        }

        // enable logging of replica events
        for(int ns: range(n_system)) {
            auto logger = systems[ns].logger;
            if(!logger) continue;
            if(static_cast<int>(logger->level) < static_cast<int>(LOG_BASIC)) continue;

            auto* replica_ptr = &replica_indices[ns];
            logger->add_logger<int>("replica_index", {1}, [replica_ptr](int* buffer){buffer[0] = *replica_ptr;});

            auto* swap_vectors = &participating_swaps[ns];
            logger->log_once<int>("replica_swap_partner", {int(swap_vectors->size())},[swap_vectors,ns](int* buffer){
                    for(int i: range(swap_vectors->size())) {
                        auto sw = (*swap_vectors)[i];
                        // write down the system that is *not* this system
                        buffer[i] = (sw->sys1!=ns ? sw->sys1 : sw->sys2);
                    }});

            logger->add_logger<int>("replica_cumulative_swaps", {int(swap_vectors->size()), 2}, 
                  [swap_vectors](int* buffer) {
                    for(int i: range(swap_vectors->size())) {
                        auto sw = (*swap_vectors)[i];
                        buffer[2*i+0] = sw->n_success;
                        buffer[2*i+1] = sw->n_attempt;
                    }});
        }
    }

    void reset_stats() {
        for(auto& ss: swap_sets)
            for(auto& sw: ss)
                sw.n_success = sw.n_attempt = 0u;
    }

    void attempt_swaps(uint32_t seed, uint64_t round, vector<System>& systems, int exchange_criterion ) {
        int n_system = systems.size();

        vector<float> beta;
        for(auto &sys: systems) beta.push_back(1.f/sys.temperature);

        // compute the boltzmann factors for everyone
        auto compute_log_boltzmann = [&]() {
            vector<float> result(n_system);
            for(int i=0; i<n_system; ++i) {
                systems[i].engine.compute(PotentialAndDerivMode);
                result[i] = -beta[i]*systems[i].engine.potential;
            }
            return result;
        };

        // swap coordinates and the associated system indices
        auto coord_swap = [&](int ns1, int ns2) {
            swap(systems[ns1].engine.pos->output, systems[ns2].engine.pos->output);
            swap(replica_indices[ns1], replica_indices[ns2]);
        };

        RandomGenerator random(seed, REPLICA_EXCHANGE_RANDOM_STREAM, 0u, round);

        int swap_select = n_attempt_swaps%n_swap_sets;

        for(auto& set: swap_sets) {
            // FIXME the first energy computation is unnecessary if we are not on the first swap set
            // It is important that the energy is computed more than once in case
            // we are doing Hamiltonian parallel tempering rather than 
            // temperature parallel tempering

            if (set[0].set_id != swap_select)
                continue;
            
            if (exchange_criterion == 0) {
                auto old_lboltz = compute_log_boltzmann();
                for(auto& swap_pair: set) coord_swap(swap_pair.sys1, swap_pair.sys2);
                auto new_lboltz  = compute_log_boltzmann();

                // reverse all swaps that should not occur by metropolis criterion
                for(auto& swap_pair: set) {
                    auto s1 = swap_pair.sys1; 
                    auto s2 = swap_pair.sys2;
                    swap_pair.n_attempt++;

                    float lboltz_diff = (new_lboltz[s1] + new_lboltz[s2]) - (old_lboltz[s1]+old_lboltz[s2]);
                    // If we reject the swap, we must reverse it
                    if(lboltz_diff < 0.f && expf(lboltz_diff) < random.uniform_open_closed().x()) {
                        coord_swap(s1,s2);
                    } else {
                        swap_pair.n_success++;
                    }
                }
            }
            else if (exchange_criterion == 1) {
                auto lboltz  = compute_log_boltzmann();

                // reverse all swaps that should not occur by metropolis criterion
                for(auto& swap_pair: set) {
                    auto s1 = swap_pair.sys1; 
                    auto s2 = swap_pair.sys2;
                    swap_pair.n_attempt++;
                    float lboltz_diff = lboltz[s2] - lboltz[s1];
                    // If we reject the swap, we must reverse it
                    if(lboltz_diff >= 0.f || expf(lboltz_diff) >= random.uniform_open_closed().x()) {
                        coord_swap(s1,s2);
                        swap_pair.n_success++;
                    }
                }
            }
        }
        n_attempt_swaps += 1;
    }
};

struct CurvatureChange {

    uniform_real_distribution<float> distribution;

    CurvatureChange(vector<System>& systems ): distribution(-1,1) {}

    void attempt_change(uint32_t seed, uint64_t round, System& sys, float relative_change  ) {

        float beta = 1.f/sys.temperature;

        RandomGenerator random(seed, REPLICA_EXCHANGE_RANDOM_STREAM, 0u, round);
        mt19937 rng;
        rng.seed(seed);

        CoordNode* ccenter = nullptr;
        for(auto &n:  sys.engine.nodes) {
            if(is_prefix(n.name, "Const3D_curvature_center")) {
                ccenter = dynamic_cast<CoordNode*>(n.computation.get());
                break;
            }
        }

        float memb_potential = 0.f;
        for(auto &n:  sys.engine.nodes) {
            if(is_prefix(n.name, "cb_membrane_potential") or is_prefix(n.name, "hb_membrane_potential")) {
                n.computation->compute_value(PotentialAndDerivMode);
                auto pot_node = static_cast<PotentialNode*>(n.computation.get());
                memb_potential += pot_node->potential;
            }
            else if(is_prefix(n.name, "cb_surf_membrane_potential") or is_prefix(n.name, "hb_surf_membrane_potential")) {
                n.computation->compute_value(PotentialAndDerivMode);
                auto pot_node = static_cast<PotentialNode*>(n.computation.get());
                memb_potential += pot_node->potential;
            }
        }

        float rand_value = ((float) rand()/RAND_MAX - 0.5)*2.;
        float centerz = ccenter->output.get_mutable_host_ptr()[0 * ccenter->elem_width + 2];
        float dcenterz = relative_change*centerz*rand_value;
        ccenter->output.get_mutable_host_ptr()[0 * ccenter->elem_width + 2] += dcenterz;

        float new_memb_potential = 0.f;
        for(auto &n:  sys.engine.nodes) {
            if(is_prefix(n.name, "cb_membrane_potential") or is_prefix(n.name, "hb_membrane_potential")) {
                n.computation->compute_value(PotentialAndDerivMode);
                auto pot_node = static_cast<PotentialNode*>(n.computation.get());
                new_memb_potential += pot_node->potential;
            }
            else if(is_prefix(n.name, "cb_surf_membrane_potential") or is_prefix(n.name, "hb_surf_membrane_potential")) {
                n.computation->compute_value(PotentialAndDerivMode);
                auto pot_node = static_cast<PotentialNode*>(n.computation.get());
                new_memb_potential += pot_node->potential;
            }
        }

        //cout << dcenterz << " " << rand_value << " " << relative_change << " " << centerz << " || " << new_memb_potential << " " << memb_potential << endl;

        float old_lboltz = -beta*memb_potential;
        float new_lboltz = -beta*new_memb_potential;

        float lboltz_diff = new_lboltz - old_lboltz;
        if(lboltz_diff < 0.f && expf(lboltz_diff) < random.uniform_open_closed().x()) {
            ccenter->output.get_mutable_host_ptr()[0 * ccenter->elem_width + 2] -= dcenterz;
        }

    }
};


vector<float> potential_deriv_agreement(DerivEngine& engine) {
    vector<float> relative_error;
    int n_atom = engine.pos->n_elem;
    VecArray pos_array(engine.pos->output.get_mutable_host_ptr(), engine.pos->elem_width);

    vector<float> input(n_atom*3);
    for(int na=0; na<n_atom; ++na)
        for(int d=0; d<3; ++d)
            input[na*3+d] = pos_array(d,na);
    std::vector<float> output(1);

    auto do_compute = [&]() {
        for(int na=0; na<n_atom; ++na)
            for(int d=0; d<3; ++d)
                pos_array(d,na) = input[na*3+d];
        engine.compute(PotentialAndDerivMode);
        output[0] = engine.potential;
    };

    for(auto &n: engine.nodes) {
        if(n.computation->potential_term) {
            auto &v = dynamic_cast<PotentialNode&>(*n.computation.get()).potential;
            printf("%s: % 4.3f\n", n.name.c_str(), v);
        }
    }
    printf("\n\n");

    auto central_diff_jac = central_difference_deriviative(do_compute, input, output, 1e-3);
    vector<float> deriv_array;
    VecArray sens_array(engine.pos->sens.get_mutable_host_ptr(), engine.pos->elem_width);
    for(int na=0; na<n_atom; ++na)
        for(int d=0; d<3; ++d)
            deriv_array.push_back(sens_array(d,na));

    relative_error.push_back(
            relative_rms_deviation(central_diff_jac, deriv_array));
    return relative_error;
}

int upside_main(int argc, const char* const * argv, int verbose=1)
try {
    using namespace TCLAP;  // Templatized C++ Command Line Parser (tclap.sourceforge.net)
    CmdLine cmd("Using Protein Statistical Information for Dynamics Estimation (Upside)\n Author: John Jumper, Xiangda Peng, Nabil Faruk", 
            ' ', "2.0alpha");

    ValueArg<double> time_step_arg("", "time-step", "time step for integration (default 0.009)", 
            false, 0.009, "float", cmd);
    ValueArg<double> duration_arg("", "duration", "duration of simulation", 
            true, -1., "float", cmd);
    ValueArg<double> time_lim_arg("", "time-limit", "Run time limit of simulation in seconds (default unlimited)", 
            false, -1., "float", cmd);
    ValueArg<unsigned long> seed_arg("", "seed", "random seed (default 42)", 
            false, 42l, "int", cmd);
    ValueArg<string> temperature_arg("", "temperature", "thermostat temperature (default 1.0, "
            "should be comma-separated list of temperatures). If running a single system, a single temperature is fine)", 
            false, "", "temperature_list", cmd);
    MultiArg<string> swap_set_args("","swap-set", "list like 0-1,2-3,6-7,4-8 of non-overlapping swaps for a replica "
            "exchange.  May be specified multiple times for multiple swap sets (non-overlapping is only required "
            "within a single swap set).", false, "h5_files");
    cmd.add(swap_set_args);
    ValueArg<double> anneal_factor_arg("", "anneal-factor", "annealing factor (0.1 means the final temperature "
            "will be 10% of the initial temperature)", 
            false, 1., "float", cmd);
    ValueArg<double> anneal_duration_arg("", "anneal-duration", "duration of annealing phase "
            "(default is duration of simulation)", 
            false, -1., "float", cmd);

    ValueArg<double> anneal_start_arg("", "anneal-start", "start annealing phase ",
            false, -1., "float", cmd);

    ValueArg<double> anneal_end_arg("", "anneal-end", "end annealing phase ", 
            false, -1., "float", cmd);

    ValueArg<double> frame_interval_arg("", "frame-interval", "simulation time between frames", 
            true, -1., "float", cmd);
    ValueArg<double> dense_frame_interval_arg("", "dense-frame-interval", "simulation time between twe dense outputs", 
            false, -1., "float", cmd);
    ValueArg<double> replica_interval_arg("", "replica-interval", 
            "simulation time between applications of replica exchange (0 means no replica exchange, default 0.)", 
            false, 0., "float", cmd);
    ValueArg<int> exchange_criterion_arg("", "exchange-criterion", 
            "the way of calculating exchange criteria (0 means using the total energy difference of two boltzmann " 
            "before and after the exchanging, 1 means using the energy difference between two boltzmann, default 0 )", 
            false, 0, "int", cmd);
    ValueArg<double> mc_interval_arg("", "monte-carlo-interval", 
            "simulation time between attempts to do Monte Carlo moves (0. means no MC moves, default 0.)", 
            false, 0., "float", cmd);
    ValueArg<double> thermostat_interval_arg("", "thermostat-interval", 
            "simulation time between applications of the thermostat", 
            false, -1., "float", cmd);
    ValueArg<double> thermostat_timescale_arg("", "thermostat-timescale", "timescale for the thermostat", 
            false, 5., "float", cmd);

    ValueArg<double> curvature_changer_interval_arg("", "curvature-changer-interval", 
            "simulation time between applications of curvature change (0 means no curvature change, default 0.)", 
            false, 0., "float", cmd);

    ValueArg<double> relative_curvature_radius_change_arg("", "relative-curvature-radius-change", 
            "Maximum amount of curvature radius adjustment (default 0.05)", 
            false, 0.05, "float", cmd);

    ValueArg<string> integrator_arg("", "integrator", 
            "Use this option to control which Integrator are used.  Available levels are v(verlet) or mv(multi-step verlet). "
            "Default is verlet.",
            false, "", "v, mv ", cmd);
    ValueArg<int> inner_step_arg("", "inner-step", "inner step for the integrator", false, 3, "int", cmd);

    ValueArg<string> input_arg("i", "input", "h5df input file for position", false, "not_Defined_By_user", "string", cmd);
    ValueArg<string> input_base_arg("", "input-base", "h5df input files base for positions", false, "not_Defined_By_user", "string_list", cmd);
    ValueArg<string> output_arg("o", "output", "h5df output log file", false, "not_Defined_By_user", "string", cmd);
    ValueArg<string> output_base_arg("", "output-base", "the base name of h5df output log files.", false, "not_Defined_By_user", "string", cmd);
    SwitchArg disable_recenter_arg("", "disable-recentering", 
            "Disable all recentering of protein in the universe", 
            cmd, false);
    SwitchArg disable_z_recenter_arg("", "disable-z-recentering", 
            "Disable z-recentering of protein in the universe", 
            cmd, false);
    SwitchArg raise_signal_on_exit_if_received_arg("", "re-raise-signal", 
            "(Developer use only) Used for obscure details of signal handling.  No effect on simulation.", 
            cmd, false);
    ValueArg<string> log_level_arg("", "log-level", 
            "Use this option to control which arrays are stored in /output.  Available levels are basic, detailed, "
            "or extensive.  Default is detailed.",
            false, "", "basic, detailed, extensive", cmd);
    SwitchArg potential_deriv_agreement_arg("", "potential-deriv-agreement",
            "(developer use only) check the agreement of the derivative with finite differences "
            "of the potential for the initial structure.  This may give strange answers for native structures "
            "(no steric clashes may given an agreement of NaN) or random structures (where bonds and angles are "
            "exactly at their equilibrium values).  Interpret these results at your own risk.", cmd, false);
    SwitchArg record_momentum_arg("", "record-momentum",
            "record the momentum (so that the trajectory can be exactly restarted)"
            " the momentum will be recorded in output.mom ",
            cmd, false);
    SwitchArg restart_using_momentum_arg("", "restart-using-momentum",
            "restart the trajectory by initializing using the momentum stored in input.mom,"
            " this is usually helpful when the simulation ends due to the wall time."
            " To restart the trajectory, make sure to copy the end momentum of last run to input.mom (similar to the pos treatment when restarting):"
            " check examples for continue the simulation",
            cmd, false);
    ValueArg<string> set_param_arg("", "set-param", "Developer use only", false, "", "param_arg", cmd);
    UnlabeledMultiArg<string> config_args("config_files","configuration .h5 files", true, "h5_files");
    cmd.add(config_args);
    cmd.parse(argc, argv);

    try {
        if(verbose) printf("invocation: ");
        std::string invocation(argv[0]);
        for(auto arg=argv+1; arg!=argv+argc; ++arg) invocation += string(" ") + *arg;
        if(verbose) printf("%s\n", invocation.c_str());

        map<string,vector<float>> set_param_map;
        if(set_param_arg.getValue().size()) {
            auto param_file = h5_obj(H5Fclose, H5Fopen(set_param_arg.getValue().c_str(),
                        H5F_ACC_RDONLY, H5P_DEFAULT));

            for(const string& node_name: node_names_in_group(param_file.get(), ".")) {
                set_param_map[node_name] = vector<float>();
                auto& values = set_param_map[node_name];
                traverse_dset<1,float>(param_file.get(), node_name.c_str(), [&](size_t i, float x) {
                        values.push_back(x);});
            }
        }


        float dt = time_step_arg.getValue();
        int inner_step = 3;
        if  (integrator_arg.getValue() == "mv" )
            inner_step = inner_step_arg.getValue();

        double duration = duration_arg.getValue();
        double time_lim = time_lim_arg.getValue();
        bool passed_time_lim = false;
        uint64_t n_round = round(duration / (inner_step*dt));
        int thermostat_interval = max(1.,round(thermostat_interval_arg.getValue() / (inner_step*dt))); //  FIXME inner_step
        int frame_interval = max(1.,round(frame_interval_arg.getValue() / (inner_step*dt)));
        int dense_output_interval = max(1.,round(dense_frame_interval_arg.getValue() / (inner_step*dt)));

        unsigned long big_prime = 4294967291ul;  // largest prime smaller than 2^32
        uint32_t base_random_seed = uint32_t(seed_arg.getValue() % big_prime);

        // initialize thermostat and thermalize momentum
        if(verbose) printf("random seed: %lu\n", (unsigned long)(base_random_seed));

        int mc_interval = mc_interval_arg.getValue() > 0. 
            ? max(1,int(mc_interval_arg.getValue()/(inner_step*dt))) 
            : 0;

        int duration_print_width = ceil(log(1+duration)/log(10));

        bool do_recenter = !disable_recenter_arg.getValue();
        bool xy_recenter_only = do_recenter && disable_z_recenter_arg.getValue();

        h5_noerr(H5Eset_auto(H5E_DEFAULT, nullptr, nullptr));
        vector<string> config_paths = config_args.getValue();
        vector<System> systems(config_paths.size());

        auto temperature_strings = split_string(temperature_arg.getValue(), ",");
        if(temperature_strings.size() != 1u && temperature_strings.size() != systems.size()) 
            throw string("Received "+to_string(temperature_strings.size())+" temperatures but have "
                    +to_string(systems.size())+" systems");

        for(int ns: range(systems.size())) {
            float T = stod_strict(temperature_strings.size()>1u ? temperature_strings[ns] : temperature_strings[0]);
            systems[ns].initial_temperature = T;
        }

        double anneal_factor = anneal_factor_arg.getValue();
        double anneal_duration = anneal_duration_arg.getValue();
        if(anneal_duration == -1.) anneal_duration = duration;

        double anneal_start = anneal_start_arg.getValue();
        if (anneal_start < 0.0) anneal_start = 0.0;
        double anneal_end = anneal_end_arg.getValue();
        if (anneal_end > anneal_start) anneal_duration = anneal_end-anneal_start;

        // tighter spacing at the low end of temperatures because the variance is decreasing
        auto anneal_temp = [=](double initial_temperature, double time) {
            auto fraction = max(0., (time-anneal_start) / anneal_duration);
            double T0 = initial_temperature;
            double T1 = initial_temperature*anneal_factor;
            if (time <= anneal_start)
                return T0;
            else if (time > anneal_end)
                return T1;
            else 
                return sqr(sqrt(T0)*(1.-fraction) + sqrt(T1)*fraction);
        };

        vector<string> outputs(systems.size());
        bool user_defined_output = false;

        auto out_name = output_arg.getValue();
        if (out_name != "not_Defined_By_user") {
            auto output_strings = split_string(out_name, ",");

            if(output_strings.size() != 1u && output_strings.size() != systems.size()) 
                throw string("Received "+to_string(output_strings.size())+" outputs but have "
                        +to_string(systems.size())+" systems");

            for(int ns: range(systems.size())) 
                outputs[ns] = output_strings.size()>1u ? output_strings[ns] : output_strings[0];

            user_defined_output = true;
        }

        auto out_base = output_base_arg.getValue();
        if (out_base != "not_Defined_By_user")  {
            for(int ns: range(systems.size())) 
                outputs[ns] = out_base + "_" + to_string(ns) + ".h5";
            user_defined_output = true;
        }
        
        vector<string> inputs(systems.size());
        bool user_defined_input = false;

        auto in_name = input_arg.getValue();
        if (in_name != "not_Defined_By_user") {
            auto input_strings = split_string(in_name, ",");

            if(input_strings.size() != 1u && input_strings.size() != systems.size()) 
                throw string("Received "+to_string(input_strings.size())+" inputs but have "
                        +to_string(systems.size())+" systems");

            for(int ns: range(systems.size())) 
                inputs[ns] = input_strings.size()>1u ? input_strings[ns] : input_strings[0];

            user_defined_input = true;
        }
        auto in_base = input_base_arg.getValue();
        if (in_base != "not_Defined_By_user")  {
            for(int ns: range(systems.size())) 
                inputs[ns] = in_base + "_" + to_string(ns) + ".h5";
            user_defined_input = true;
        }
        int replica_interval = 0;
        if(replica_interval_arg.getValue())
            replica_interval = max(1.,replica_interval_arg.getValue()/(inner_step*dt));

        int exchange_criterion = exchange_criterion_arg.getValue();

        int curvature_changer_interval = 0;
        if(curvature_changer_interval_arg.getValue())
            curvature_changer_interval = max(1.,curvature_changer_interval_arg.getValue()/(inner_step*dt));
        float relative_curvature_radius_change = relative_curvature_radius_change_arg.getValue();

        // system 0 is the minimum temperature
        int n_system = systems.size();

        // We are not allowed to exit an OpenMP critical section early.  For this reason, we must trap
        // all exceptions.  To avoid crashing callers, we simply record the presence of an exception
        // then exit immediately after the block.
        bool error_exit_omp = false;
        #pragma omp critical
        for(int ns=0; ns<n_system; ++ns) try {
            System* sys = &systems[ns];  // a pointer here makes later lambda's more natural
            sys->random_seed = base_random_seed + ns;

            try {
                if (user_defined_output) {
                    sys->config = h5_obj(H5Fclose,
                        H5Fopen(config_paths[ns].c_str(), H5F_ACC_RDONLY, H5P_DEFAULT));
                }
                else {
                    sys->config = h5_obj(H5Fclose,
                        H5Fopen(config_paths[ns].c_str(), H5F_ACC_RDWR, H5P_DEFAULT));
                }
            } catch(string &s) {
                throw string("Unable to open configuration file at ") + config_paths[ns];
            }

            if (user_defined_input) {
                try {
                    sys->input = h5_obj(H5Fclose,
                            H5Fopen(inputs[ns].c_str(), H5F_ACC_RDONLY, H5P_DEFAULT));
                } catch(string &s) {
                    throw string("Unable to open input position file ") + inputs[ns];
                }
            }

            if (user_defined_output) {
                sys->output = h5_obj(H5Fclose, 
                   H5Fcreate(outputs[ns].c_str(), H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT));
            }
            else {
                if(h5_exists(sys->config.get(), "output")) {
                    // Note that it is not possible in HDF5 1.8.x to reclaim space by deleting
                    // datasets or groups.  Subsequent h5repack will reclaim space, however.
                    h5_noerr(H5Ldelete(sys->config.get(), "/output", H5P_DEFAULT));
                }
            }


            LogLevel log_level;
            if     (log_level_arg.getValue() == "")          log_level = LOG_DETAILED;
            else if(log_level_arg.getValue() == "basic")     log_level = LOG_BASIC;
            else if(log_level_arg.getValue() == "detailed")  log_level = LOG_DETAILED;
            else if(log_level_arg.getValue() == "extensive") log_level = LOG_EXTENSIVE;
            else throw string("Illegal value for --log-level");

            if (user_defined_output) 
                sys->logger = make_shared<H5Logger>(sys->output, "output", log_level);
            else
                sys->logger = make_shared<H5Logger>(sys->config, "output", log_level);

            default_logger = sys->logger;  // FIXME kind of a hack for the ugly global variable

            if (user_defined_output) 
                write_string_attribute(sys->output.get(), "output", "invocation", invocation);
            else
                write_string_attribute(sys->config.get(), "output", "invocation", invocation);

            auto pos_shape = get_dset_size(3, sys->config.get(), "/input/pos");
            if (user_defined_input) 
                pos_shape = get_dset_size(3, sys->input.get(), "/input/pos");

            sys->n_atom = pos_shape[0];

            if(pos_shape[1]!=3) throw string("invalid dimensions for initial position");
            if(pos_shape[2]!=1) throw string("must have n_system 1 from config");

            auto potential_group = open_group(sys->config.get(), "/input/potential");
            sys->engine = initialize_engine_from_hdf5(sys->n_atom, potential_group.get());
            if  (integrator_arg.getValue() == "mv" )
                sys->engine.build_integrator_levels(true, dt, inner_step );

            // Override parameters as instructed by users
            for(const auto& p: set_param_map)
                sys->engine.get(p.first).computation->set_param(p.second);


            if (user_defined_input) 
                traverse_dset<3,float>(sys->input.get(), "/input/pos", [&](size_t na, size_t d, size_t ns, float x) { 
                        sys->engine.pos->output.get_mutable_host_ptr()[na * sys->engine.pos->elem_width + d] = x;});
            else
                traverse_dset<3,float>(sys->config.get(), "/input/pos", [&](size_t na, size_t d, size_t ns, float x) { 
                        sys->engine.pos->output.get_mutable_host_ptr()[na * sys->engine.pos->elem_width + d] = x;});

            if(verbose) printf("%s\nn_atom %i\n\n", config_paths[ns].c_str(), sys->n_atom);

            if(potential_deriv_agreement_arg.getValue()){
                sys->engine.compute(PotentialAndDerivMode);
                if(verbose) printf("Initial potential:\n");
                auto relative_error = potential_deriv_agreement(sys->engine);
                if(verbose) printf("overall potential relative error: ");
                for(auto r: relative_error) printf(" %.5f", r);
                if(verbose) printf("\n");
            }

            sys->thermostat = OrnsteinUhlenbeckThermostat(
                    sys->random_seed,
                    thermostat_timescale_arg.getValue(),
                    1.,
                    1e8);
            sys->set_temperature(sys->initial_temperature);
            sys->thermostat.set_delta_t(thermostat_interval*inner_step*dt);  // set true thermostat interval  //  FIXME inner_step

            sys->mom.reset(new device_buffer<float>(sys->n_atom * 3)); // Initialize momentum buffer
            if (restart_using_momentum_arg.getValue()) { // initialize momentum using input.mom if requested
                if (user_defined_input) {
                    if (h5_exists(sys->input.get(), "input/mom")) {
                        traverse_dset<3,float>(sys->input.get(), "/input/mom", [&](size_t na, size_t d, size_t ns, float x) { 
                            sys->mom->get_mutable_host_ptr()[na * 3 + d] = x;}); // Use get_mutable_host_ptr and direct indexing
                    }
                    else throw  string("input h5 file doesn't have input.mom group, can't restart using the momentum!");
                }
                else {
                    if (h5_exists(sys->config.get(), "input/mom")) {
                        traverse_dset<3,float>(sys->config.get(), "/input/mom", [&](size_t na, size_t d, size_t ns, float x) { 
                                sys->mom->get_mutable_host_ptr()[na * 3 + d] = x;}); // Use get_mutable_host_ptr and direct indexing
                    }
                    else throw  string("input h5 file doesn't have input.mom group, can't restart using the momentum!");
                }
            }
            else {
                // Initialize momentum to zeros using the host pointer
                std::fill_n(sys->mom->get_mutable_host_ptr(), sys->n_atom * 3, 0.f);
                sys->thermostat.apply(VecArray(sys->mom->get_mutable_host_ptr(), 3), sys->n_atom); // initial thermalization if it's a fresh start
            }


            // we must capture the sys pointer by value here so that it is available later
            sys->logger->add_logger<float>("pos", {1, sys->n_atom, 3}, [sys](float* pos_buffer) {
                    VecArray pos_array(sys->engine.pos->output.get_mutable_host_ptr(), sys->engine.pos->elem_width);
                    for(int na=0; na<sys->n_atom; ++na) 
                    for(int d=0; d<3; ++d) 
                    pos_buffer[na*3 + d] = pos_array(d,na);
                    });
            if (record_momentum_arg.getValue()) { // record the momentum if requested, with the same frequency as the position recording
                sys->logger->add_logger<float>("mom", {1, sys->n_atom, 3}, [sys](float* mom_buffer) {
                        VecArray mom_array(sys->mom->get_mutable_host_ptr(), 3); // Use get_mutable_host_ptr and elem_width 3
                        for(int na=0; na<sys->n_atom; ++na) 
                        for(int d=0; d<3; ++d) 
                        mom_buffer[na*3 + d] = mom_array(d,na);
                        });
                
            }
            sys->logger->add_logger<double>("kinetic", {1}, [sys](double* kin_buffer) {
                    double sum_kin = 0.f;
                    for(int na=0; na<sys->n_atom; ++na) sum_kin += mag2(load_vec<3>(VecArray(sys->mom->get_mutable_host_ptr(), 3),na)); // Use get_mutable_host_ptr and elem_width 3
                    kin_buffer[0] = (0.5/sys->n_atom)*sum_kin;  // kinetic_energy = (1/2) * <mom^2>
                    });
            sys->logger->add_logger<double>("potential", {1}, [sys](double* pot_buffer) {
                    sys->engine.compute(PotentialAndDerivMode);
                    pot_buffer[0] = sys->engine.potential;});
            sys->logger->add_logger<double>("time", {}, [sys,dt,inner_step](double* time_buffer) {
                    *time_buffer=inner_step*dt*sys->round_num;});

            if(mc_interval) {
                // sys->mc_samplers = MultipleMonteCarloSampler{open_group(sys->config.get(), "/input/sampler_group").get(), *sys->logger};
                sys->mc_samplers = MultipleMonteCarloSampler{open_group(sys->config.get(), "/input").get(), *sys->logger};
            }

            // quick hack of a check for z-centering and membrane potential
            if(do_recenter && !xy_recenter_only) {
                for(auto &n: sys->engine.nodes) {
                    if(is_prefix(n.name, "membrane_potential") || is_prefix(n.name, "z_flat_bottom") || is_prefix(n.name, "tension") || is_prefix(n.name, "AFM"))
                        throw string("You have z-centering and a z-dependent potential turned on.  "
                                "This is not what you want.  Consider --disable-z-recentering "
                                "or --disable-recentering.");
                }
            }

            if(do_recenter) {
                for(auto &n: sys->engine.nodes) {
                    if(is_prefix(n.name, "cavity_radial") || is_prefix(n.name, "spherical_well"))
                        throw string("You have re-centering and a radial potential turned on.  "
                                "This is not what you want.  Consider --disable-recentering.");
                }
            }


        } catch(const string &e) {
            fprintf(stderr, "\n\nERROR: %s\n", e.c_str());
            error_exit_omp = true;
        } catch(...) {
            fprintf(stderr, "\n\nERROR: unknown error\n");
            error_exit_omp = true;
        }
        // We have just left the critical section
        if(error_exit_omp) return 2;
        default_logger = shared_ptr<H5Logger>();  // FIXME kind of a hack for the ugly global variable

        unique_ptr<ReplicaExchange> replex;
        if(replica_interval) {
            if(verbose) printf("initializing replica exchange\n");
            replex.reset(new ReplicaExchange(systems, swap_set_args.getValue()));
            if(!replex->swap_sets.size()) throw string("replica exchange requested but no swap sets proposed");
        }


        if(replica_interval) {
            int n_atom = systems[0].n_atom;
            for(System& sys: systems) 
                if(sys.n_atom != n_atom) 
                    throw string("Replica exchange requires all systems have the same number of atoms");
        }

        unique_ptr<CurvatureChange> curvature_changer;
        if(curvature_changer_interval) {
            if(verbose) printf("initializing curvature changer\n");
            curvature_changer.reset(new CurvatureChange(systems));
        }

        if(verbose) printf("\n");
        for(int ns: range(systems.size())) {
            if(verbose) printf("%i %.2f\n", ns, systems[ns].temperature);
            float* temperature_pointer = &(systems[ns].temperature);
            systems[ns].logger->add_logger<double>("temperature", {1}, [temperature_pointer](double* temperature_buffer) {
                    temperature_buffer[0] = *temperature_pointer;});
        }
        if(verbose) printf("\n");

        if(verbose) printf("Initial potential energy:");
        for(System& sys: systems) {
            sys.engine.compute(PotentialAndDerivMode);
            if(verbose) printf(" %.2f", sys.engine.potential);
        }
        if(verbose) printf("\n");


        // Install signal handlers to dump state only when the simulation has really started.  This is intended to prevent
        // loss of buffered data and to present final statistics.  It is especially useful when being killed due to running 
        // out of time on a cluster.
        SignalHandlerHandler sigint_handler (SIGINT,  abort_like_handler);
        SignalHandlerHandler sigterm_handler(SIGTERM, abort_like_handler);

        // we need to run everyone until the next synchronization event
        // a little care is needed if we are multiplexing the events
        auto tstart = chrono::high_resolution_clock::now();
        while(systems[0].round_num < n_round && received_signal==NO_SIGNAL) {
            int last_start = systems[0].round_num;
            #pragma omp parallel for schedule(static,1)
            for(int ns=0; ns<int(systems.size()); ++ns) {
                System& sys = systems[ns];
                for(bool do_break=false; (!do_break) && (sys.round_num<n_round); ++sys.round_num) {
                    int nr = sys.round_num;

                    // Check for stop signal somewhat infrequently to avoid any (possibly theoretical)
                    // performance cost on a NUMA machine
                    if((nr%8==ns%8)) {
                        if (received_signal!=NO_SIGNAL) {
                            break;
                        }

                    // Check if run time limit exceeded 
                    if (time_lim > 0.) {
                        auto elapsed = chrono::duration<double>(std::chrono::high_resolution_clock::now() - tstart).count();
                        // printf("Currently at %.1f seconds\n", elapsed);
                        if (elapsed > time_lim) {
                            passed_time_lim = true;
                            break;
                        }
                    }    
                } 

                // Don't pivot at t=0 so that a partially strained system may relax before the
                // first pivot
                if(nr && mc_interval && !(nr%mc_interval)) 
                    sys.mc_samplers.execute(sys.random_seed, nr, sys.temperature, sys.engine);

                if(!frame_interval || !(nr%frame_interval)) {
                    if(do_recenter) recenter(VecArray(sys.engine.pos->output.get_mutable_host_ptr(), sys.engine.pos->elem_width), xy_recenter_only, sys.n_atom);
                    sys.engine.compute(PotentialAndDerivMode);
                    sys.logger->collect_samples();

                    double Rg = 0.f;
                    float3 com = make_vec3(0.f, 0.f, 0.f);
                    for(int na=0; na<sys.n_atom; ++na)
                        com += load_vec<3>(VecArray(sys.engine.pos->output.get_mutable_host_ptr(), sys.engine.pos->elem_width), na);
                    com *= 1.f/sys.n_atom;

                    for(int na=0; na<sys.n_atom; ++na) 
                        Rg += mag2(load_vec<3>(VecArray(sys.engine.pos->output.get_mutable_host_ptr(), sys.engine.pos->elem_width),na)-com);
                    Rg = sqrtf(Rg/sys.n_atom);

                        if(verbose) printf(
                                "%*.0f / %*.0f elapsed %2i system %.2f temp %5.1f hbonds, Rg %5.1f A, potential % 8.2f\n", 
                                duration_print_width, nr*double(dt*inner_step), 
                                duration_print_width, duration, 
                                ns, sys.temperature,
                                get_n_hbond(sys.engine), Rg, sys.engine.potential);
                        fflush(stdout);
                    }

                    if(!dense_output_interval || !(nr%dense_output_interval)) {
                        sys.logger->collect_dense_samples();
                    }

                    if(!(nr%thermostat_interval)) {
                        // Handle simulated annealing if applicable
                        if(anneal_factor != 1.)
                            sys.set_temperature(anneal_temp(sys.initial_temperature, inner_step*dt*(sys.round_num+1)));
                        sys.thermostat.apply(VecArray(sys.mom->get_mutable_host_ptr(), 3), sys.n_atom); // Create VecArray from device_buffer
                    }

                    if  (integrator_arg.getValue() == "mv" )
                        sys.engine.integration_cycle(*sys.mom, dt, inner_step); // Dereference unique_ptr
                    else
                        sys.engine.integration_cycle(*sys.mom, dt); // Dereference unique_ptr

                    if(curvature_changer_interval && !(sys.round_num % curvature_changer_interval))
                        curvature_changer->attempt_change(base_random_seed, sys.round_num, sys, relative_curvature_radius_change);

                    do_break = nr>last_start && replica_interval && !((nr+1)%replica_interval);
                }
            }
            // Here we are running in serial again
            if(received_signal!=NO_SIGNAL) break;
            if(passed_time_lim) break;

            if(replica_interval && !(systems[0].round_num % replica_interval))
                replex->attempt_swaps(base_random_seed, systems[0].round_num, systems, exchange_criterion);

        }



        if(received_signal!=NO_SIGNAL) {fprintf(stderr, "Received early termination signal\n");}
        if(passed_time_lim) {fprintf(stderr, "Passed time limit\n");}
        for(auto& sys: systems) sys.logger = shared_ptr<H5Logger>(); // release shared_ptr, which also flushes data during destructor

        auto elapsed = chrono::duration<double>(std::chrono::high_resolution_clock::now() - tstart).count();
        if(verbose)
            printf("\n\nfinished in %.1f seconds (%.2f us/systems/step, %.1e simulation_time_unit/hour)\n",
                elapsed,
                elapsed*1e6/systems.size()/systems[0].round_num/inner_step, 
                systems[0].round_num*inner_step*dt/elapsed * 3600.); 

        if(verbose) printf("\navg_kinetic_energy/1.5kT");
        for(auto& sys: systems) {
            double sum_kinetic = 0.;
            long n_kinetic = 0l;

            size_t tot_frames;
            if (user_defined_output) 
                tot_frames = get_dset_size(2, sys.output.get(), "/output/kinetic")[0];
            else
                tot_frames = get_dset_size(2, sys.config.get(), "/output/kinetic")[0];

            if (user_defined_output) 
                traverse_dset<2,float>(sys.output.get(),"/output/kinetic", [&](size_t nf, size_t ns, float x){
                    if(nf>tot_frames/2){ sum_kinetic+=x; n_kinetic++; }
                });
            else 
                traverse_dset<2,float>(sys.config.get(),"/output/kinetic", [&](size_t nf, size_t ns, float x){
                    if(nf>tot_frames/2){ sum_kinetic+=x; n_kinetic++; }
                });

            if(verbose) printf(" % .3f", sum_kinetic/n_kinetic / (1.5*sys.temperature));
        }
        if(verbose) printf("\n");

        // FIXME this code should be moved into MC sampler code
        try {
            if(mc_interval) {
                if(verbose)printf("pivot_success:\n");
                for(auto& sys: systems) {
                    std::vector<int64_t> ps(2,0);

                    if (user_defined_output) 
                        traverse_dset<2,int>(sys.output.get(), "/output/pivot_stats", [&](size_t nf, int d, int x) {ps[d] += x;});
                    else
                        traverse_dset<2,int>(sys.config.get(), "/output/pivot_stats", [&](size_t nf, int d, int x) {ps[d] += x;});

                    if(verbose)printf(" % .4f", double(ps[0])/double(ps[1]));
                }
                if(verbose)printf("\n");
            }
        } catch(...) {}  // stats reporting is optional

        try {
            if(mc_interval) {
                if(verbose)printf("jump_success:\n");
                for(auto& sys: systems) {
                    std::vector<int64_t> ps(2,0);

                    if (user_defined_output) 
                        traverse_dset<2,int>(sys.output.get(), "/output/jump_stats", [&](size_t nf, int d, int x) {ps[d] += x;});
                    else 
                        traverse_dset<2,int>(sys.config.get(), "/output/jump_stats", [&](size_t nf, int d, int x) {ps[d] += x;});

                    if(verbose)printf(" % .4f", double(ps[0])/double(ps[1]));
                }
                if(verbose)printf("\n");
            }
        } catch(...) {}  // stats reporting is optional

#ifdef COLLECT_PROFILE
        if(verbose) {
            printf("\n");
            global_time_keeper.print_report(inner_step*systems[0].round_num+1); //  FIXME inner_step
            printf("\n");
        }
#endif
    } catch(const string &e) {
        fprintf(stderr, "\n\nERROR: %s\n", e.c_str());
        return 1;
    } catch(...) {
        fprintf(stderr, "\n\nERROR: unknown error\n");
        return 1;
    }

    // By this point in the program, the signal handlers have been returned to the handlers installed
    // by the caller if Upside is running as a shared library function.  When we re-raise the signal,
    // the caller's handler will be able to take the signal.
    if(raise_signal_on_exit_if_received_arg.getValue() && received_signal!=NO_SIGNAL)
        raise(received_signal);

    return 0;
} catch(const TCLAP::ArgException &e) { 
    fprintf(stderr, "\n\nERROR: %s for argument %s\n", e.error().c_str(), e.argId().c_str());
    return 1;
} catch(const string &e) {
    fprintf(stderr, "\n\nERROR: %s\n", e.c_str());
    return 1;
}

int main(int argc, const char* const * argv) {
    return upside_main(argc, argv);
}

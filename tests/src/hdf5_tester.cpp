#include <gtest/gtest.h>
#include <iostream>
#include <vector>
#include <string>
#include <cmath>

#include "deriv_engine.h"
#include "h5_support.h"
#include "device_buffer.h"
#include "timing.h"

using namespace std;
using namespace h5;

extern bool cuda_acceleration;

class HDF5Tester : public ::testing::Test {
protected:
    void SetUp() override {
        // Set up the HDF5 file path
        // Assuming tests are run from the build/tests directory
        hdf5_path = "../../example/01.GettingStarted/outputs/simple_test/chig.run.up";
    }

    void TearDown() override {
    }

    std::string hdf5_path;

    // Helper to extract a node's output buffer
    std::vector<float> extract_output(const CoordNode* node) {
        const VecArrayStorage* storage = node->output.h_ptr();
        if (!storage || !storage->x) return {};
        size_t total_size = storage->n_elem * storage->row_width;
        return std::vector<float>(storage->x.get(), storage->x.get() + total_size);
    }

    // Helper to extract a node's sensitivity buffer
    std::vector<float> extract_sens(const CoordNode* node) {
        const VecArrayStorage* storage = node->sens.h_ptr();
        if (!storage || !storage->x) return {};
        size_t total_size = storage->n_elem * storage->row_width;
        return std::vector<float>(storage->x.get(), storage->x.get() + total_size);
    }

    // Assert array equivalence
    void assert_arrays_equal(const std::vector<float>& expected, const std::vector<float>& actual, double tolerance = 1e-4) {
        ASSERT_EQ(expected.size(), actual.size());
        for (size_t i = 0; i < expected.size(); ++i) {
            if (!std::isfinite(expected[i]) || !std::isfinite(actual[i])) {
                ASSERT_EQ(std::isfinite(expected[i]), std::isfinite(actual[i])) << "Finite mismatch at index " << i;
                continue;
            }
            double diff = std::abs(expected[i] - actual[i]);
            double max_val = std::max(std::abs(expected[i]), std::abs(actual[i]));
            if (max_val > 1e-4) {
                ASSERT_LE(diff / max_val, 5e-3) << "Relative error exceeded at index " << i 
                    << " (Expected: " << expected[i] << ", Actual: " << actual[i] << ")";
            } else {
                ASSERT_LE(diff, 1e-4) << "Absolute error exceeded at index " << i 
                    << " (Expected: " << expected[i] << ", Actual: " << actual[i] << ")";
            }
        }
    }
};

TEST_F(HDF5Tester, CompareCPUandGPU) {
#ifdef USE_CUDA
    // 1. Load the engine from HDF5
    H5Obj config = h5_obj(H5Fclose, H5Fopen(hdf5_path.c_str(), H5F_ACC_RDONLY, H5P_DEFAULT));
    ASSERT_TRUE(config.get() >= 0) << "Failed to open HDF5 file: " << hdf5_path;

    auto pos_shape = get_dset_size(3, config.get(), "/input/pos");
    int n_atom = pos_shape[0];
    
    auto potential_group = open_group(config.get(), "/input/potential");
    DerivEngine engine = initialize_engine_from_hdf5(n_atom, potential_group.get());

    // Load initial positions into engine.pos
    traverse_dset<3,float>(config.get(), "/input/pos", [&](size_t na, size_t d, size_t ns, float x) { 
        const_cast<VecArrayStorage&>(*engine.pos->output.h_ptr())(d,na) = x;
    });

    // 2. Run on CPU
    cuda_acceleration = false;
    engine.compute(PotentialAndDerivMode);

    // Cache CPU results
    float cpu_potential = engine.potential;
    std::map<std::string, std::vector<float>> cpu_outputs;
    std::map<std::string, std::vector<float>> cpu_sens;

    for (const auto& node : engine.nodes) {
        if (!node.computation->potential_term) {
            auto coord_node = static_cast<CoordNode*>(node.computation.get());
            cpu_outputs[node.name] = extract_output(coord_node);
            cpu_sens[node.name] = extract_sens(coord_node);
        }
    }

    std::cout << "CPU Potential: " << cpu_potential << std::endl;

    // Reset positions (just in case) and clear potential
    traverse_dset<3,float>(config.get(), "/input/pos", [&](size_t na, size_t d, size_t ns, float x) { 
        const_cast<VecArrayStorage&>(*engine.pos->output.h_ptr())(d,na) = x;
    });
    engine.potential = 0.0f;

    // 3. Run on GPU
    cuda_acceleration = true;
    engine.compute(PotentialAndDerivMode);

    float gpu_potential = engine.potential;
    
    std::cout << "GPU Potential: " << gpu_potential << std::endl;

    // Compare potentials
    double diff = std::abs(cpu_potential - gpu_potential);
    double max_val = std::max(std::abs(cpu_potential), std::abs(gpu_potential));
    if (max_val > 1e-4) {
        EXPECT_LE(diff / max_val, 1e-4) << "Total potential mismatch!";
    } else {
        EXPECT_LE(diff, 1e-4) << "Total potential mismatch!";
    }

    // Compare all nodes
    for (const auto& node : engine.nodes) {
        if (!node.computation->potential_term) {
            auto coord_node = static_cast<CoordNode*>(node.computation.get());
            std::cout << "Validating GPU output for node: " << node.name << std::endl;
            
            auto gpu_output = extract_output(coord_node);
            auto gpu_sens = extract_sens(coord_node);

            // Note: Currently, only AngleCoord and DistCoord are ported to GPU!
            // We should expect them to match perfectly.
            assert_arrays_equal(cpu_outputs[node.name], gpu_output, 1e-4);
            assert_arrays_equal(cpu_sens[node.name], gpu_sens, 1e-4);
        }
    }
#else
    GTEST_SKIP() << "CUDA not enabled, skipping GPU comparison test.";
#endif
}

int main(int argc, char **argv) {
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}

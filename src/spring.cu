#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include "device_utils.h"
#include <stdio.h>

// CUDA kernel for computing spring forces and potential
__global__ void spring_kernel(
    const float* __restrict__ pos_data,     // Position data for all atoms
    const int* __restrict__ ids,            // Atom IDs [n_elem]
    const float* __restrict__ equil_dist,   // Equilibrium distances [n_elem]
    const float* __restrict__ spring_const, // Spring constants [n_elem]
    float* __restrict__ pos_sens,           // Position sensitivities (forces)
    float* __restrict__ potential,          // Global potential accumulator
    int n_elem,                             // Number of spring elements
    int stride,                             // Stride for position arrays (4 for Float4)
    int dim1,                               // Dimension index to use
    bool pbc,                               // Periodic boundary conditions flag
    float box_len                           // Box length for PBC
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (idx >= n_elem) return;
    
    // Get atom ID and spring parameters
    int atom_id = ids[idx];
    float eq_dist = equil_dist[idx];
    float k = spring_const[idx];
    
    // Get position in the specified dimension
    float dist = pos_data[atom_id * stride + dim1];
    
    // Compute excess displacement
    float excess = dist - eq_dist;
    
    // Apply periodic boundary conditions if enabled
    if (pbc && box_len > 0.0f) {
        float excess1 = dist - eq_dist - box_len;
        float excess2 = dist - eq_dist + box_len;
        
        float sqr_excess = excess * excess;
        float sqr_excess1 = excess1 * excess1;
        float sqr_excess2 = excess2 * excess2;
        
        if (sqr_excess1 < sqr_excess) {
            excess = excess1;
            sqr_excess = sqr_excess1;
        }
        if (sqr_excess2 < sqr_excess) {
            excess = excess2;
        }
    }
    
    // Skip if no displacement
    if (excess == 0.0f) return;
    
    // Compute potential contribution and force
    float delta_potential = 0.5f * k * excess * excess;
    float force = k * excess;
    
    // Accumulate potential (atomic operation for thread safety)
    atomicAdd(potential, delta_potential);
    
    // Accumulate force (atomic operation for thread safety)
    atomicAdd(&pos_sens[atom_id * stride + dim1], force);
}

// Launcher function for spring kernel
void launch_spring_kernel(
    const float* pos_data,
    const int* ids,
    const float* equil_dist,
    const float* spring_const,
    float* pos_sens,
    float* potential,
    int n_elem,
    int stride,
    int dim1,
    bool pbc,
    float box_len,
    int threadsPerBlock
) {
    if (n_elem == 0) return;
    
    int blocksPerGrid = (n_elem + threadsPerBlock - 1) / threadsPerBlock;
    
    spring_kernel<<<blocksPerGrid, threadsPerBlock>>>(
        pos_data, ids, equil_dist, spring_const, pos_sens, potential,
        n_elem, stride, dim1, pbc, box_len
    );
    
    CUDA_CHECK_LAST_ERROR();
}

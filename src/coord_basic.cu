#include "coord_basic.h"
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <stdio.h>

// CUDA kernel for computing distances
__global__ void distcoord_compute_kernel(
    const float* __restrict__ pos1_data,  // Position data for first atom set
    const float* __restrict__ pos2_data,  // Position data for second atom set  
    const int* __restrict__ atom_pairs,   // Atom index pairs [n_elem*2]
    float* __restrict__ output_data,      // Output distances [n_elem]
    float* __restrict__ deriv_data,       // Derivative data [n_elem*3]
    int n_elem,                          // Number of distance calculations
    int stride                           // Stride for position arrays (4 for Float4 alignment)
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (idx >= n_elem) return;
    
    // Get atom indices for this distance calculation
    int atom1_idx = atom_pairs[idx * 2 + 0];
    int atom2_idx = atom_pairs[idx * 2 + 1];
    
    // Load positions (assuming Float4 storage with stride=4)
    float3 pos1 = make_float3(
        pos1_data[atom1_idx * stride + 0],
        pos1_data[atom1_idx * stride + 1], 
        pos1_data[atom1_idx * stride + 2]
    );
    
    float3 pos2 = make_float3(
        pos2_data[atom2_idx * stride + 0],
        pos2_data[atom2_idx * stride + 1],
        pos2_data[atom2_idx * stride + 2]  
    );
    
    // Compute displacement vector
    float3 disp = make_float3(
        pos1.x - pos2.x,
        pos1.y - pos2.y, 
        pos1.z - pos2.z
    );
    
    // Compute distance
    float dist_sq = disp.x * disp.x + disp.y * disp.y + disp.z * disp.z;
    float dist = sqrtf(dist_sq);
    
    // Store distance
    output_data[idx] = dist;
    
    // Compute and store derivative (unit vector)
    if (dist > 1e-8f) {
        float inv_dist = 1.0f / dist;
        deriv_data[idx * 3 + 0] = disp.x * inv_dist;
        deriv_data[idx * 3 + 1] = disp.y * inv_dist;
        deriv_data[idx * 3 + 2] = disp.z * inv_dist;
    } else {
        deriv_data[idx * 3 + 0] = 0.0f;
        deriv_data[idx * 3 + 1] = 0.0f;
        deriv_data[idx * 3 + 2] = 0.0f;
    }
}

// CUDA kernel for propagating derivatives
__global__ void distcoord_deriv_kernel(
    const int* __restrict__ atom_pairs,    // Atom index pairs [n_elem*2]
    const float* __restrict__ deriv_data,  // Derivative data [n_elem*3]
    const float* __restrict__ sens_data,   // Sensitivity data [n_elem]
    float* __restrict__ pos1_sens,         // Position sensitivity for first atom set
    float* __restrict__ pos2_sens,         // Position sensitivity for second atom set
    int n_elem,                           // Number of distance calculations
    int stride                            // Stride for position arrays
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (idx >= n_elem) return;
    
    // Get atom indices for this distance calculation
    int atom1_idx = atom_pairs[idx * 2 + 0];
    int atom2_idx = atom_pairs[idx * 2 + 1];
    
    // Get sensitivity value
    float sens = sens_data[idx];
    
    // Get derivative vector
    float3 deriv = make_float3(
        deriv_data[idx * 3 + 0],
        deriv_data[idx * 3 + 1],
        deriv_data[idx * 3 + 2]
    );
    
    // Scale derivative by sensitivity
    float3 scaled_deriv = make_float3(
        deriv.x * sens,
        deriv.y * sens,
        deriv.z * sens
    );
    
    // Accumulate derivatives (atomic operations for thread safety)
    atomicAdd(&pos1_sens[atom1_idx * stride + 0], scaled_deriv.x);
    atomicAdd(&pos1_sens[atom1_idx * stride + 1], scaled_deriv.y);
    atomicAdd(&pos1_sens[atom1_idx * stride + 2], scaled_deriv.z);
    
    atomicAdd(&pos2_sens[atom2_idx * stride + 0], -scaled_deriv.x);
    atomicAdd(&pos2_sens[atom2_idx * stride + 1], -scaled_deriv.y);
    atomicAdd(&pos2_sens[atom2_idx * stride + 2], -scaled_deriv.z);
}

// Launcher functions
void distcoord_compute_device(
    const float* pos1_data, const float* pos2_data,
    const int* atom_pairs, float* output_data, float* deriv_data,
    int n_elem, int stride, int threadsPerBlock
) {
    int blocksPerGrid = (n_elem + threadsPerBlock - 1) / threadsPerBlock;
    
    distcoord_compute_kernel<<<blocksPerGrid, threadsPerBlock>>>(
        pos1_data, pos2_data, atom_pairs, output_data, deriv_data, n_elem, stride
    );
}

void distcoord_deriv_device(
    const int* atom_pairs, const float* deriv_data, const float* sens_data,
    float* pos1_sens, float* pos2_sens,
    int n_elem, int stride, int threadsPerBlock
) {
    int blocksPerGrid = (n_elem + threadsPerBlock - 1) / threadsPerBlock;
    
    distcoord_deriv_kernel<<<blocksPerGrid, threadsPerBlock>>>(
        atom_pairs, deriv_data, sens_data, pos1_sens, pos2_sens, n_elem, stride
    );
}

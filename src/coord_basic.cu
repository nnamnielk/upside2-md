#include "coord_basic.h"
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <stdio.h>

// CUDA kernel for computing distances
__global__ void distcoord_compute_kernel(
    const float* __restrict__ pos1_data,
    const float* __restrict__ pos2_data,
    const float* __restrict__ atom_pairs,
    float* __restrict__ output_data,
    float* __restrict__ deriv_data,
    int n_elem,
    int pos_stride,
    int param_stride,
    int deriv_stride,
    int out_stride
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (idx >= n_elem) return;
    
    // Get atom indices for this distance calculation
    int atom1_idx = __float2int_rn(atom_pairs[idx * param_stride + 0]);
    int atom2_idx = __float2int_rn(atom_pairs[idx * param_stride + 1]);
    
    // Load positions (assuming Float4 storage with stride=4)
    float3 pos1 = make_float3(
        pos1_data[atom1_idx * pos_stride + 0],
        pos1_data[atom1_idx * pos_stride + 1],
        pos1_data[atom1_idx * pos_stride + 2]
    );
    
    float3 pos2 = make_float3(
        pos2_data[atom2_idx * pos_stride + 0],
        pos2_data[atom2_idx * pos_stride + 1],
        pos2_data[atom2_idx * pos_stride + 2]
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
    output_data[idx * out_stride] = dist;
    
    // Compute and store derivative (unit vector)
    if (dist > 1e-8f) {
        float inv_dist = 1.0f / dist;
        deriv_data[idx * deriv_stride + 0] = disp.x * inv_dist;
        deriv_data[idx * deriv_stride + 1] = disp.y * inv_dist;
        deriv_data[idx * deriv_stride + 2] = disp.z * inv_dist;
    } else {
        deriv_data[idx * deriv_stride + 0] = 0.0f;
        deriv_data[idx * deriv_stride + 1] = 0.0f;
        deriv_data[idx * deriv_stride + 2] = 0.0f;
    }
}

// CUDA kernel for propagating derivatives
__global__ void distcoord_deriv_kernel(
    const float* __restrict__ atom_pairs,
    const float* __restrict__ deriv_data,
    const float* __restrict__ sens_data,
    float* __restrict__ pos1_sens,
    float* __restrict__ pos2_sens,
    int n_elem,
    int pos_stride,
    int param_stride,
    int deriv_stride
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (idx >= n_elem) return;
    
    // Get atom indices for this distance calculation
    int atom1_idx = __float2int_rn(atom_pairs[idx * param_stride + 0]);
    int atom2_idx = __float2int_rn(atom_pairs[idx * param_stride + 1]);
    
    // Get sensitivity value
    float sens = sens_data[idx];
    
    // Get derivative vector
    float3 deriv = make_float3(
        deriv_data[idx * deriv_stride + 0],
        deriv_data[idx * deriv_stride + 1],
        deriv_data[idx * deriv_stride + 2]
    );
    
    // Scale derivative by sensitivity
    float3 scaled_deriv = make_float3(
        deriv.x * sens,
        deriv.y * sens,
        deriv.z * sens
    );
    
    // Accumulate derivatives (atomic operations for thread safety)
    atomicAdd(&pos1_sens[atom1_idx * pos_stride + 0], scaled_deriv.x);
    atomicAdd(&pos1_sens[atom1_idx * pos_stride + 1], scaled_deriv.y);
    atomicAdd(&pos1_sens[atom1_idx * pos_stride + 2], scaled_deriv.z);
    
    atomicAdd(&pos2_sens[atom2_idx * pos_stride + 0], -scaled_deriv.x);
    atomicAdd(&pos2_sens[atom2_idx * pos_stride + 1], -scaled_deriv.y);
    atomicAdd(&pos2_sens[atom2_idx * pos_stride + 2], -scaled_deriv.z);
}

// Launcher functions
void distcoord_compute_device(
    const float* pos1_data, const float* pos2_data,
    const float* atom_pairs, float* output_data, float* deriv_data,
    int n_elem, int pos_stride, int threadsPerBlock,
    int param_stride_elems, int deriv_stride_elems, int output_stride_elems
) {
    int blocksPerGrid = (n_elem + threadsPerBlock - 1) / threadsPerBlock;
    
    distcoord_compute_kernel<<<blocksPerGrid, threadsPerBlock>>>(
        pos1_data, pos2_data, atom_pairs, output_data, deriv_data,
        n_elem, pos_stride, param_stride_elems, deriv_stride_elems, output_stride_elems
    );
}

void distcoord_deriv_device(
    const float* atom_pairs, const float* deriv_data, const float* sens_data,
    float* pos1_sens, float* pos2_sens,
    int n_elem, int pos_stride, int threadsPerBlock,
    int param_stride_elems, int deriv_stride_elems
) {
    int blocksPerGrid = (n_elem + threadsPerBlock - 1) / threadsPerBlock;
    
    distcoord_deriv_kernel<<<blocksPerGrid, threadsPerBlock>>>(
        atom_pairs, deriv_data, sens_data, pos1_sens, pos2_sens,
        n_elem, pos_stride, param_stride_elems, deriv_stride_elems
    );
}

// CUDA kernel for computing angles
__global__ void anglecoord_compute_kernel(
    const float* __restrict__ pos_data,
    const float* __restrict__ atom_triplets,
    float* __restrict__ output_data,
    float* __restrict__ deriv1_data,
    float* __restrict__ deriv2_data,
    float* __restrict__ deriv3_data,
    int n_elem,
    int pos_stride,
    int param_stride,
    int deriv_stride,
    int out_stride
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx >= n_elem) return;

    // Get atom indices
    int atom1_idx = __float2int_rn(atom_triplets[idx * param_stride + 0]);
    int atom2_idx = __float2int_rn(atom_triplets[idx * param_stride + 1]);
    int atom3_idx = __float2int_rn(atom_triplets[idx * param_stride + 2]);

    // Load positions
    float3 atom1 = make_float3(pos_data[atom1_idx * pos_stride + 0], pos_data[atom1_idx * pos_stride + 1], pos_data[atom1_idx * pos_stride + 2]);
    float3 atom2 = make_float3(pos_data[atom2_idx * pos_stride + 0], pos_data[atom2_idx * pos_stride + 1], pos_data[atom2_idx * pos_stride + 2]);
    float3 atom3 = make_float3(pos_data[atom3_idx * pos_stride + 0], pos_data[atom3_idx * pos_stride + 1], pos_data[atom3_idx * pos_stride + 2]);

    // Compute vectors from the central atom (atom3)
    float3 x1 = make_float3(atom1.x - atom3.x, atom1.y - atom3.y, atom1.z - atom3.z);
    float3 x2 = make_float3(atom2.x - atom3.x, atom2.y - atom3.y, atom2.z - atom3.z);

    // Inverse magnitudes
    float inv_d1 = rsqrtf(x1.x * x1.x + x1.y * x1.y + x1.z * x1.z);
    float inv_d2 = rsqrtf(x2.x * x2.x + x2.y * x2.y + x2.z * x2.z);

    // Normalized vectors
    float3 x1h = make_float3(x1.x * inv_d1, x1.y * inv_d1, x1.z * inv_d1);
    float3 x2h = make_float3(x2.x * inv_d2, x2.y * inv_d2, x2.z * inv_d2);

    // Dot product
    float dp = x1h.x * x2h.x + x1h.y * x2h.y + x1h.z * x2h.z;
    output_data[idx * out_stride] = dp;

    // Derivatives
    float3 deriv1 = make_float3((x2h.x - x1h.x * dp) * inv_d1, (x2h.y - x1h.y * dp) * inv_d1, (x2h.z - x1h.z * dp) * inv_d1);
    float3 deriv2 = make_float3((x1h.x - x2h.x * dp) * inv_d2, (x1h.y - x2h.y * dp) * inv_d2, (x1h.z - x2h.z * dp) * inv_d2);
    float3 deriv3 = make_float3(-deriv1.x - deriv2.x, -deriv1.y - deriv2.y, -deriv1.z - deriv2.z);

    // Store derivatives
    deriv1_data[idx * deriv_stride + 0] = deriv1.x;
    deriv1_data[idx * deriv_stride + 1] = deriv1.y;
    deriv1_data[idx * deriv_stride + 2] = deriv1.z;

    deriv2_data[idx * deriv_stride + 0] = deriv2.x;
    deriv2_data[idx * deriv_stride + 1] = deriv2.y;
    deriv2_data[idx * deriv_stride + 2] = deriv2.z;

    deriv3_data[idx * deriv_stride + 0] = deriv3.x;
    deriv3_data[idx * deriv_stride + 1] = deriv3.y;
    deriv3_data[idx * deriv_stride + 2] = deriv3.z;
    
    // Ensure all memory writes are committed before kernel completion
    __threadfence();
}

// CUDA kernel for propagating angle derivatives
__global__ void anglecoord_deriv_kernel(
    const float* __restrict__ atom_triplets,
    const float* __restrict__ deriv1_data,
    const float* __restrict__ deriv2_data,
    const float* __restrict__ deriv3_data,
    const float* __restrict__ sens_data,
    float* __restrict__ pos_sens,
    int n_elem,
    int pos_stride,
    int param_stride,
    int deriv_stride
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx >= n_elem) return;

    // Get atom indices
    int atom1_idx = __float2int_rn(atom_triplets[idx * param_stride + 0]);
    int atom2_idx = __float2int_rn(atom_triplets[idx * param_stride + 1]);
    int atom3_idx = __float2int_rn(atom_triplets[idx * param_stride + 2]);

    // Get sensitivity value
    float sens = sens_data[idx];

    // Load derivatives
    float3 d1 = make_float3(deriv1_data[idx * deriv_stride + 0], deriv1_data[idx * deriv_stride + 1], deriv1_data[idx * deriv_stride + 2]);
    float3 d2 = make_float3(deriv2_data[idx * deriv_stride + 0], deriv2_data[idx * deriv_stride + 1], deriv2_data[idx * deriv_stride + 2]);
    float3 d3 = make_float3(deriv3_data[idx * deriv_stride + 0], deriv3_data[idx * deriv_stride + 1], deriv3_data[idx * deriv_stride + 2]);

    // Accumulate derivatives scaled by sensitivity
    atomicAdd(&pos_sens[atom1_idx * pos_stride + 0], d1.x * sens);
    atomicAdd(&pos_sens[atom1_idx * pos_stride + 1], d1.y * sens);
    atomicAdd(&pos_sens[atom1_idx * pos_stride + 2], d1.z * sens);

    atomicAdd(&pos_sens[atom2_idx * pos_stride + 0], d2.x * sens);
    atomicAdd(&pos_sens[atom2_idx * pos_stride + 1], d2.y * sens);
    atomicAdd(&pos_sens[atom2_idx * pos_stride + 2], d2.z * sens);

    atomicAdd(&pos_sens[atom3_idx * pos_stride + 0], d3.x * sens);
    atomicAdd(&pos_sens[atom3_idx * pos_stride + 1], d3.y * sens);
    atomicAdd(&pos_sens[atom3_idx * pos_stride + 2], d3.z * sens);
}

// Launcher functions for AngleCoord
void anglecoord_compute_device(
    const float* pos_data, const float* atom_triplets,
    float* output_data, float* deriv1_data, float* deriv2_data, float* deriv3_data,
    int n_elem, int pos_stride, int threadsPerBlock,
    int param_stride_elems, int deriv_stride_elems, int output_stride_elems
) {
    int blocksPerGrid = (n_elem + threadsPerBlock - 1) / threadsPerBlock;
    anglecoord_compute_kernel<<<blocksPerGrid, threadsPerBlock>>>(
        pos_data, atom_triplets, output_data, deriv1_data, deriv2_data, deriv3_data,
        n_elem, pos_stride, param_stride_elems, deriv_stride_elems, output_stride_elems
    );
}

void anglecoord_deriv_device(
    const float* atom_triplets,
    const float* deriv1_data, const float* deriv2_data, const float* deriv3_data,
    const float* sens_data, float* pos_sens,
    int n_elem, int pos_stride, int threadsPerBlock,
    int param_stride_elems, int deriv_stride_elems
) {
    int blocksPerGrid = (n_elem + threadsPerBlock - 1) / threadsPerBlock;
    anglecoord_deriv_kernel<<<blocksPerGrid, threadsPerBlock>>>(
        atom_triplets, deriv1_data, deriv2_data, deriv3_data, sens_data, pos_sens,
        n_elem, pos_stride, param_stride_elems, deriv_stride_elems
    );
}

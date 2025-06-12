#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

// Simple CUDA error checking macro
#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

// Kernel to check if particles have moved beyond the cache buffer
__global__ void check_cache_validity_kernel(
    int* d_rebuild_flag,
    int n_elem,
    const float* __restrict__ aligned_pos,
    const float* __restrict__ cache_pos,
    const int* __restrict__ id,
    const int* __restrict__ cache_id,
    float max_cache_dist2,
    int pos_stride)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n_elem) return;

    if (atomicCAS(d_rebuild_flag, 1, 1) == 1) return; // Early exit if another thread already flagged for rebuild

    // Check ID change
    if (id[i] != cache_id[i]) {
        atomicCAS(d_rebuild_flag, 0, 1);
        return;
    }

    // Check position deviation with correct stride
    float dx = aligned_pos[i*pos_stride + 0] - cache_pos[i*4 + 0];
    float dy = aligned_pos[i*pos_stride + 1] - cache_pos[i*4 + 1];
    float dz = aligned_pos[i*pos_stride + 2] - cache_pos[i*4 + 2];
    float dist2 = dx*dx + dy*dy + dz*dz;

    if (dist2 > max_cache_dist2) {
        atomicCAS(d_rebuild_flag, 0, 1);
    }
}

// Kernel to refine cached edges on the GPU
__global__ void find_edges_kernel(
    int* d_n_edge,
    int cache_n_edge,
    int max_n_edge,
    float cutoff2,
    bool symmetric,
    int pos1_stride, int pos2_stride,
    int n_elem1, int n_elem2,
    const int32_t* __restrict__ d_cache_edge_indices1, const int32_t* __restrict__ d_cache_edge_indices2,
    const int32_t* __restrict__ d_cache_edge_id1,      const int32_t* __restrict__ d_cache_edge_id2,
    const float* __restrict__ d_aligned_pos1,    const float* __restrict__ d_aligned_pos2,
    int32_t* __restrict__ d_edge_indices1, int32_t* __restrict__ d_edge_indices2,
    int32_t* __restrict__ d_edge_id1,      int32_t* __restrict__ d_edge_id2)
{
    int i_edge = blockIdx.x * blockDim.x + threadIdx.x;
    if (i_edge >= cache_n_edge) return;

    int32_t i1 = d_cache_edge_indices1[i_edge];
    int32_t i2 = d_cache_edge_indices2[i_edge];

    // Add bounds checking
    if (i1 >= n_elem1 || i2 >= n_elem2 || i1 < 0 || i2 < 0) return;

    const float* p1 = d_aligned_pos1 + pos1_stride * i1;
    const float* p2 = d_aligned_pos2 + pos2_stride * i2;

    float dx = p1[0] - p2[0];
    float dy = p1[1] - p2[1];
    float dz = p1[2] - p2[2];
    float dist2 = dx*dx + dy*dy + dz*dz;

    if (dist2 < cutoff2) {
        int ne = atomicAdd(d_n_edge, 1);
        // Add bounds checking for atomic result
        if (ne >= max_n_edge) return;
        d_edge_indices1[ne] = i1;
        d_edge_indices2[ne] = i2;
        d_edge_id1[ne]      = d_cache_edge_id1[i_edge];
        d_edge_id2[ne]      = d_cache_edge_id2[i_edge];
    }
}


// C-style wrapper functions to be called from interaction_graph.h
extern "C" {

bool ensure_cache_valid_cuda(
    int n_elem1, int n_elem2, bool symmetric,
    const float* aligned_pos1, const int pos1_stride, const int* id1, // Use const for input pointers
    const float* aligned_pos2, const int pos2_stride, const int* id2,
    float cache_cutoff, float cutoff,
    const float* cache_pos1, const float* cache_pos2,
    const int* cache_id1, const int* cache_id2)
{
    int* d_rebuild_flag;
    gpuErrchk(cudaMalloc(&d_rebuild_flag, sizeof(int)));
    gpuErrchk(cudaMemset(d_rebuild_flag, 0, sizeof(int)));

    // <<< MODIFICATION START >>>
    // Allocate device memory for all kernel inputs
    float* d_aligned_pos1, *d_cache_pos1, *d_aligned_pos2, *d_cache_pos2;
    int *d_id1, *d_cache_id1, *d_id2, *d_cache_id2;

    gpuErrchk(cudaMalloc(&d_aligned_pos1, n_elem1 * pos1_stride * sizeof(float)));
    gpuErrchk(cudaMalloc(&d_cache_pos1,   n_elem1 * 4 * sizeof(float))); // cache_pos is always stride 4
    gpuErrchk(cudaMalloc(&d_id1,          n_elem1 * sizeof(int)));
    gpuErrchk(cudaMalloc(&d_cache_id1,    n_elem1 * sizeof(int)));

    // Copy data from host to device
    gpuErrchk(cudaMemcpy(d_aligned_pos1, aligned_pos1, n_elem1 * pos1_stride * sizeof(float), cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(d_cache_pos1,   cache_pos1,   n_elem1 * 4 * sizeof(float),           cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(d_id1,          id1,          n_elem1 * sizeof(int),                 cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(d_cache_id1,    cache_id1,    n_elem1 * sizeof(int),                 cudaMemcpyHostToDevice));
    // <<< MODIFICATION END >>>

    float max_cache_dist2 = 0.25f * (cache_cutoff - cutoff) * (cache_cutoff - cutoff);
    int threadsPerBlock = 256;

    // Check first set of elements
    int blocks1 = (n_elem1 + threadsPerBlock - 1) / threadsPerBlock;
    // <<< MODIFICATION: Use device pointers in kernel launch >>>
    check_cache_validity_kernel<<<blocks1, threadsPerBlock>>>(
        d_rebuild_flag, n_elem1, d_aligned_pos1, d_cache_pos1, d_id1, d_cache_id1, max_cache_dist2, pos1_stride);

    // Check second set if not symmetric
    if (!symmetric) {
        // <<< MODIFICATION START >>>
        // Allocate and copy data for the second set of elements
        gpuErrchk(cudaMalloc(&d_aligned_pos2, n_elem2 * pos2_stride * sizeof(float)));
        gpuErrchk(cudaMalloc(&d_cache_pos2,   n_elem2 * 4 * sizeof(float)));
        gpuErrchk(cudaMalloc(&d_id2,          n_elem2 * sizeof(int)));
        gpuErrchk(cudaMalloc(&d_cache_id2,    n_elem2 * sizeof(int)));

        gpuErrchk(cudaMemcpy(d_aligned_pos2, aligned_pos2, n_elem2 * pos2_stride * sizeof(float), cudaMemcpyHostToDevice));
        gpuErrchk(cudaMemcpy(d_cache_pos2,   cache_pos2,   n_elem2 * 4 * sizeof(float),           cudaMemcpyHostToDevice));
        gpuErrchk(cudaMemcpy(d_id2,          id2,          n_elem2 * sizeof(int),                 cudaMemcpyHostToDevice));
        gpuErrchk(cudaMemcpy(d_cache_id2,    cache_id2,    n_elem2 * sizeof(int),                 cudaMemcpyHostToDevice));
        // <<< MODIFICATION END >>>

        int blocks2 = (n_elem2 + threadsPerBlock - 1) / threadsPerBlock;
        // <<< MODIFICATION: Use device pointers in kernel launch >>>
        check_cache_validity_kernel<<<blocks2, threadsPerBlock>>>(
            d_rebuild_flag, n_elem2, d_aligned_pos2, d_cache_pos2, d_id2, d_cache_id2, max_cache_dist2, pos2_stride);
    }
    gpuErrchk(cudaPeekAtLastError());
    gpuErrchk(cudaDeviceSynchronize());

    int rebuild_flag = 0;
    gpuErrchk(cudaMemcpy(&rebuild_flag, d_rebuild_flag, sizeof(int), cudaMemcpyDeviceToHost));
    
    // <<< MODIFICATION START >>>
    // Free all the device memory we allocated
    gpuErrchk(cudaFree(d_rebuild_flag));
    gpuErrchk(cudaFree(d_aligned_pos1));
    gpuErrchk(cudaFree(d_cache_pos1));
    gpuErrchk(cudaFree(d_id1));
    gpuErrchk(cudaFree(d_cache_id1));
    if (!symmetric) {
        gpuErrchk(cudaFree(d_aligned_pos2));
        gpuErrchk(cudaFree(d_cache_pos2));
        gpuErrchk(cudaFree(d_id2));
        gpuErrchk(cudaFree(d_cache_id2));
    }
    // <<< MODIFICATION END >>>
    
    return rebuild_flag == 0; // Return true if cache is still valid
}



void find_edges_cuda(
    int& n_edge, int max_n_edge, int cache_n_edge,
    float cutoff, bool symmetric,
    int n_elem1, int n_elem2, int pos1_stride, int pos2_stride,
    const float* aligned_pos1, const float* aligned_pos2,
    const int32_t* cache_edge_indices1, const int32_t* cache_edge_indices2,
    const int32_t* cache_edge_id1,      const int32_t* cache_edge_id2,
    int32_t* edge_indices1, int32_t* edge_indices2,
    int32_t* edge_id1,      int32_t* edge_id2)
{
    // Validate input parameters
    if (n_elem1 <= 0 || n_elem2 <= 0 || cache_n_edge < 0 || max_n_edge <= 0) {
        return;
    }
    
    if (pos1_stride <= 0 || pos2_stride <= 0) {
        return;
    }
    
    // Check host pointers
    if (!aligned_pos1) { return; }
    if (!symmetric && !aligned_pos2) { return; }
    if (!cache_edge_indices1) { return; }
    if (!cache_edge_indices2) { return; }
    if (!cache_edge_id1) { return; }
    if (!cache_edge_id2) { return; }
    if (!edge_indices1) { return; }
    if (!edge_indices2) { return; }
    if (!edge_id1) { return; }
    if (!edge_id2) { return; }
    
    // Device memory allocation
    float* d_aligned_pos1 = nullptr;
    float* d_aligned_pos2 = nullptr;
    int32_t* d_cache_edge_indices1 = nullptr;
    int32_t* d_cache_edge_indices2 = nullptr;
    int32_t* d_cache_edge_id1 = nullptr;
    int32_t* d_cache_edge_id2 = nullptr;
    int32_t* d_edge_indices1 = nullptr;
    int32_t* d_edge_indices2 = nullptr;
    int32_t* d_edge_id1 = nullptr;
    int32_t* d_edge_id2 = nullptr;
    int* d_n_edge = nullptr;

    gpuErrchk(cudaMalloc((void**)&d_aligned_pos1, n_elem1 * pos1_stride * sizeof(float)));
    
    if (!symmetric) {
        gpuErrchk(cudaMalloc((void**)&d_aligned_pos2, n_elem2 * pos2_stride * sizeof(float)));
    } else {
        d_aligned_pos2 = d_aligned_pos1;
    }

    gpuErrchk(cudaMalloc((void**)&d_cache_edge_indices1, cache_n_edge * sizeof(int32_t)));
    gpuErrchk(cudaMalloc((void**)&d_cache_edge_indices2, cache_n_edge * sizeof(int32_t)));
    gpuErrchk(cudaMalloc((void**)&d_cache_edge_id1,      cache_n_edge * sizeof(int32_t)));
    gpuErrchk(cudaMalloc((void**)&d_cache_edge_id2,      cache_n_edge * sizeof(int32_t)));

    gpuErrchk(cudaMalloc((void**)&d_edge_indices1, max_n_edge * sizeof(int32_t)));
    gpuErrchk(cudaMalloc((void**)&d_edge_indices2, max_n_edge * sizeof(int32_t)));
    gpuErrchk(cudaMalloc((void**)&d_edge_id1,      max_n_edge * sizeof(int32_t)));
    gpuErrchk(cudaMalloc((void**)&d_edge_id2,      max_n_edge * sizeof(int32_t)));
    gpuErrchk(cudaMalloc((void**)&d_n_edge, sizeof(int)));
    gpuErrchk(cudaMemset(d_n_edge, 0, sizeof(int)));

    // HtoD transfers
    gpuErrchk(cudaMemcpy(d_aligned_pos1, aligned_pos1, n_elem1 * pos1_stride * sizeof(float), cudaMemcpyHostToDevice));
    
    if (!symmetric) {
        gpuErrchk(cudaMemcpy(d_aligned_pos2, aligned_pos2, n_elem2 * pos2_stride * sizeof(float), cudaMemcpyHostToDevice));
    }
    
    gpuErrchk(cudaMemcpy(d_cache_edge_indices1, cache_edge_indices1, cache_n_edge * sizeof(int32_t), cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(d_cache_edge_indices2, cache_edge_indices2, cache_n_edge * sizeof(int32_t), cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(d_cache_edge_id1,      cache_edge_id1,      cache_n_edge * sizeof(int32_t), cudaMemcpyHostToDevice));
    gpuErrchk(cudaMemcpy(d_cache_edge_id2,      cache_edge_id2,      cache_n_edge * sizeof(int32_t), cudaMemcpyHostToDevice));

    // Kernel launch
    int threadsPerBlock = 256;
    int blocks = (cache_n_edge + threadsPerBlock - 1) / threadsPerBlock;
    
    find_edges_kernel<<<blocks, threadsPerBlock>>>(
        d_n_edge, cache_n_edge, max_n_edge, cutoff * cutoff, symmetric, pos1_stride, pos2_stride,
        n_elem1, n_elem2,
        d_cache_edge_indices1, d_cache_edge_indices2, d_cache_edge_id1, d_cache_edge_id2,
        (const float*)d_aligned_pos1, (const float*)d_aligned_pos2,
        d_edge_indices1, d_edge_indices2, d_edge_id1, d_edge_id2);
    gpuErrchk(cudaPeekAtLastError());
    gpuErrchk(cudaDeviceSynchronize());

    // DtoH transfers
    gpuErrchk(cudaMemcpy(&n_edge, d_n_edge, sizeof(int), cudaMemcpyDeviceToHost));
    
    // Clamp n_edge to max_n_edge to prevent buffer overrun
    if (n_edge > max_n_edge) {
        n_edge = max_n_edge;
    }
    
    if (n_edge > 0) {
        gpuErrchk(cudaMemcpy(edge_indices1, d_edge_indices1, n_edge * sizeof(int32_t), cudaMemcpyDeviceToHost));
        gpuErrchk(cudaMemcpy(edge_indices2, d_edge_indices2, n_edge * sizeof(int32_t), cudaMemcpyDeviceToHost));
        gpuErrchk(cudaMemcpy(edge_id1,      d_edge_id1,      n_edge * sizeof(int32_t), cudaMemcpyDeviceToHost));
        gpuErrchk(cudaMemcpy(edge_id2,      d_edge_id2,      n_edge * sizeof(int32_t), cudaMemcpyDeviceToHost));
    }

    // Free memory
    cudaFree(d_aligned_pos1);
    if (!symmetric) cudaFree(d_aligned_pos2);
    cudaFree(d_cache_edge_indices1);
    cudaFree(d_cache_edge_indices2);
    cudaFree(d_cache_edge_id1);
    cudaFree(d_cache_edge_id2);
    cudaFree(d_edge_indices1);
    cudaFree(d_edge_indices2);
    cudaFree(d_edge_id1);
    cudaFree(d_edge_id2);
    cudaFree(d_n_edge);
}

} // extern "C"
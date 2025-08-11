#ifndef DEVICE_UTILS_H
#define DEVICE_UTILS_H

#ifdef __CUDACC__
#include <cuda_runtime.h>
#include <iostream>
#include <cstdlib>

// CUDA error-checking function and macro
static void assert_cuda_success(cudaError_t err, const char *file, int line) {
    if (err != cudaSuccess) {
        std::cerr << "CUDA error in " << file << " at line " << line << ": " << cudaGetErrorString(err) << std::endl;
        std::exit(EXIT_FAILURE);
    }
}

#define CUDA_ASSERT_SUCCESS(err) (assert_cuda_success(err, __FILE__, __LINE__))

// Helper macros for common CUDA operations
#define CUDA_CHECK_LAST_ERROR() CUDA_ASSERT_SUCCESS(cudaGetLastError())
#define CUDA_SYNC_CHECK() CUDA_ASSERT_SUCCESS(cudaDeviceSynchronize())

// Global device properties (initialized once)
extern cudaDeviceProp g_device_prop;
extern bool g_device_prop_initialized;

// Initialize device properties (call once at startup)
inline void initialize_device_properties() {
    if (!g_device_prop_initialized) {
        CUDA_ASSERT_SUCCESS(cudaGetDeviceProperties(&g_device_prop, 0));
        g_device_prop_initialized = true;
    }
}

// Calculate optimal block size based on data size and register pressure
inline int compute_block_size(int width, int bytes_per_element) {
    initialize_device_properties();
    int base_size = g_device_prop.maxThreadsPerBlock * 4 / bytes_per_element;
    int rounded = ((base_size + 31) / 32) * 32;
    return (rounded < 32) ? 32 : (rounded > g_device_prop.maxThreadsPerBlock) ? g_device_prop.maxThreadsPerBlock : rounded;
}

// Overload for 2D data
inline int compute_block_size(int width, int height, int bytes_per_element) {
    return compute_block_size(width * height, bytes_per_element);
}

// Overload for 3D data
inline int compute_block_size(int length, int width, int height, int bytes_per_element) {
    return compute_block_size(length * width * height, bytes_per_element);
}

#endif

#endif // DEVICE_UTILS_H

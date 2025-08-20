#ifndef SPRING_H
#define SPRING_H

#ifdef USE_CUDA
// Forward declarations for CUDA builds
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
);

#else
// Stub implementations for non-CUDA builds
#include <iostream>
#include <cstdlib>

inline void launch_spring_kernel(
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
    std::cerr << "ERROR: launch_spring_kernel called in non-CUDA mode!" << std::endl;
    std::abort();
}
#endif

#endif // SPRING_H

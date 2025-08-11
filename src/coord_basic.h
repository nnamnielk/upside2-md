#ifndef COORD_BASIC_H
#define COORD_BASIC_H

#ifndef __CUDACC__
// Stub implementations for non-CUDA builds - these should never be called when cuda_mode is false
#include <iostream>
#include <cstdlib>

inline void distcoord_compute_device(
    const float* pos1_data, const float* pos2_data,
    const int* atom_pairs, float* output_data, float* deriv_data,
    int n_elem, int stride, int threadsPerBlock
) {
    std::cerr << "ERROR: distcoord_compute_device called in non-CUDA mode!" << std::endl;
    std::abort();
}

inline void distcoord_deriv_device(
    const int* atom_pairs, const float* deriv_data, const float* sens_data,
    float* pos1_sens, float* pos2_sens,
    int n_elem, int stride, int threadsPerBlock
) {
    std::cerr << "ERROR: distcoord_deriv_device called in non-CUDA mode!" << std::endl;
    std::abort();
}
#endif

#endif

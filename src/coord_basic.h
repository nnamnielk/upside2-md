#ifndef COORD_BASIC_H
#define COORD_BASIC_H

#ifdef USE_CUDA
// Forward declarations for CUDA builds
void distcoord_compute_device(
    const float* pos1_data, const float* pos2_data,
    const int* atom_pairs, float* output_data, float* deriv_data,
    int n_elem, int stride, int threadsPerBlock
);

void distcoord_deriv_device(
    const int* atom_pairs, const float* deriv_data, const float* sens_data,
    float* pos1_sens, float* pos2_sens,
    int n_elem, int stride, int threadsPerBlock
);

void anglecoord_compute_device(
    const float* pos_data, const int* atom_triplets,
    float* output_data, float* deriv1_data, float* deriv2_data, float* deriv3_data,
    int n_elem, int stride, int threadsPerBlock
);

void anglecoord_deriv_device(
    const int* atom_triplets,
    const float* deriv1_data, const float* deriv2_data, const float* deriv3_data,
    const float* sens_data, float* pos_sens,
    int n_elem, int stride, int threadsPerBlock
);

#else
// Stub implementations for non-CUDA builds
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

inline void anglecoord_compute_device(
    const float* pos_data, const int* atom_triplets,
    float* output_data, float* deriv1_data, float* deriv2_data, float* deriv3_data,
    int n_elem, int stride, int threadsPerBlock
) {
    std::cerr << "ERROR: anglecoord_compute_device called in non-CUDA mode!" << std::endl;
    std::abort();
}

inline void anglecoord_deriv_device(
    const int* atom_triplets,
    const float* deriv1_data, const float* deriv2_data, const float* deriv3_data,
    const float* sens_data, float* pos_sens,
    int n_elem, int stride, int threadsPerBlock
) {
    std::cerr << "ERROR: anglecoord_deriv_device called in non-CUDA mode!" << std::endl;
    std::abort();
}
#endif

#endif // COORD_BASIC_H

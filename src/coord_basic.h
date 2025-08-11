#ifndef COORD_BASIC_H
#define COORD_BASIC_H

// DistCoord kernel launchers
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

#endif

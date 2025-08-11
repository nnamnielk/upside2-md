#include "device_buffer.h"
#include "vector_math.h"
#include <iostream>
#include <cstdlib>

// cuda_mode is defined in main.cpp
extern const bool cuda_mode;

template<typename T, int Dim>
DeviceBuffer<T, Dim>::DeviceBuffer(const VecArrayStorage& host) 
    : host_storage_(const_cast<VecArrayStorage*>(&host)), device_ptr_(nullptr), pitch_bytes_(0),
      host_is_dirty_(false), device_is_dirty_(false) {
    // For non-CUDA builds, we just reference the host storage
    // No device memory allocation needed
}

template<typename T, int Dim>
DeviceBuffer<T, Dim>::~DeviceBuffer() {}

template<typename T, int Dim>
DeviceBuffer<T, Dim>::DeviceBuffer(DeviceBuffer&& other) noexcept
    : host_storage_(other.host_storage_), device_ptr_(other.device_ptr_),
      pitch_bytes_(other.pitch_bytes_), host_is_dirty_(other.host_is_dirty_),
      device_is_dirty_(other.device_is_dirty_) {
    other.host_storage_ = nullptr;
    other.device_ptr_ = nullptr;
    other.pitch_bytes_ = 0;
}

template<typename T, int Dim>
DeviceBuffer<T, Dim>& DeviceBuffer<T, Dim>::operator=(DeviceBuffer&& other) noexcept {
    if (this != &other) {
        host_storage_ = other.host_storage_;
        device_ptr_ = other.device_ptr_;
        pitch_bytes_ = other.pitch_bytes_;
        host_is_dirty_ = other.host_is_dirty_;
        device_is_dirty_ = other.device_is_dirty_;
        
        other.host_storage_ = nullptr;
        other.device_ptr_ = nullptr;
        other.pitch_bytes_ = 0;
    }
    return *this;
}

template<typename T, int Dim>
void DeviceBuffer<T, Dim>::copyToDevice() {}

template<typename T, int Dim>
void DeviceBuffer<T, Dim>::copyToHost() {}

template<typename T, int Dim>
const T* DeviceBuffer<T, Dim>::devicePtr() const noexcept {
    std::cerr << "ERROR: devicePtr() called in non-CUDA mode!" << std::endl;
    std::abort();
    return nullptr;
}

template<typename T, int Dim>
size_t DeviceBuffer<T, Dim>::pitch() const noexcept {
    std::cerr << "ERROR: pitch() called in non-CUDA mode!" << std::endl;
    std::abort();
    return 0;
}

template<typename T, int Dim>
const VecArrayStorage* DeviceBuffer<T, Dim>::h_ptr() const {
    // For non-CUDA builds, just return the host storage
    return host_storage_;
}

template<typename T, int Dim>
VecArrayStorage* DeviceBuffer<T, Dim>::h_ptr() {
    // For non-CUDA builds, just return the host storage
    return host_storage_;
}

template<typename T, int Dim>
const T* DeviceBuffer<T, Dim>::d_ptr() const {
    std::cerr << "ERROR: d_ptr() called in non-CUDA mode!" << std::endl;
    std::abort();
    return nullptr;
}

template<typename T, int Dim>
T* DeviceBuffer<T, Dim>::d_ptr() {
    std::cerr << "ERROR: d_ptr() called in non-CUDA mode!" << std::endl;
    std::abort();
    return nullptr;
}

// Explicit template instantiations for the types we need
template class DeviceBuffer<float, 2>;
template class DeviceBuffer<float, 3>;
template class DeviceBuffer<int, 2>;
template class DeviceBuffer<double, 2>;

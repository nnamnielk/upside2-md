#include "device_buffer.h"
#include "vector_math.h"
#include <cuda_runtime.h>
#include <iostream>
#include <stdexcept>

// CUDA error-checking macro
static void handle_cuda_error(cudaError_t err, const char *file, int line) {
    if (err != cudaSuccess) {
        std::cerr << "CUDA error in " << file << " at line " << line << ": " << cudaGetErrorString(err) << std::endl;
        exit(EXIT_FAILURE);
    }
}
#define CUDA_CHECK(err) (handle_cuda_error(err, __FILE__, __LINE__))

template<typename T, int Dim>
DeviceBuffer<T, Dim>::DeviceBuffer(const VecArrayStorage& host)
    : host_storage_(&host), device_ptr_(nullptr), pitch_bytes_(0), 
      host_is_dirty_(true), device_is_dirty_(false) {
    
    if (Dim == 1) {
        // 1D allocation using cudaMalloc
        size_t size_bytes = host.n_elem * host.row_width * sizeof(T);
        CUDA_CHECK(cudaMalloc(&device_ptr_, size_bytes));
        pitch_bytes_ = host.row_width * sizeof(T);
    } else if (Dim == 2) {
        // 2D allocation using cudaMallocPitch
        size_t width_bytes = host.row_width * sizeof(T);
        size_t height = host.n_elem;
        CUDA_CHECK(cudaMallocPitch(reinterpret_cast<void**>(&device_ptr_), &pitch_bytes_, width_bytes, height));
    } else {
        throw std::runtime_error("DeviceBuffer only supports Dim=1 or Dim=2");
    }
}

template<typename T, int Dim>
DeviceBuffer<T, Dim>::~DeviceBuffer() {
    if (device_ptr_) {
        cudaFree(device_ptr_);
    }
}

template<typename T, int Dim>
DeviceBuffer<T, Dim>::DeviceBuffer(DeviceBuffer&& other) noexcept
    : host_storage_(other.host_storage_), 
      device_ptr_(other.device_ptr_), 
      pitch_bytes_(other.pitch_bytes_),
      host_is_dirty_(other.host_is_dirty_),
      device_is_dirty_(other.device_is_dirty_) {
    other.device_ptr_ = nullptr;
    other.pitch_bytes_ = 0;
    other.host_is_dirty_ = false;
    other.device_is_dirty_ = false;
}

template<typename T, int Dim>
DeviceBuffer<T, Dim>& DeviceBuffer<T, Dim>::operator=(DeviceBuffer&& other) noexcept {
    if (this != &other) {
        if (device_ptr_) {
            cudaFree(device_ptr_);
        }
        host_storage_ = other.host_storage_;
        device_ptr_ = other.device_ptr_;
        pitch_bytes_ = other.pitch_bytes_;
        host_is_dirty_ = other.host_is_dirty_;
        device_is_dirty_ = other.device_is_dirty_;
        other.device_ptr_ = nullptr;
        other.pitch_bytes_ = 0;
        other.host_is_dirty_ = false;
        other.device_is_dirty_ = false;
    }
    return *this;
}

template<typename T, int Dim>
void DeviceBuffer<T, Dim>::copyToDevice() {
    if (Dim == 1) {
        size_t size_bytes = host_storage_->n_elem * host_storage_->row_width * sizeof(T);
        CUDA_CHECK(cudaMemcpy(device_ptr_, host_storage_->x.get(), size_bytes, cudaMemcpyHostToDevice));
    } else if (Dim == 2) {
        size_t width_bytes = host_storage_->row_width * sizeof(T);
        size_t height = host_storage_->n_elem;
        CUDA_CHECK(cudaMemcpy2D(device_ptr_, pitch_bytes_,
                              host_storage_->x.get(), host_storage_->row_width * sizeof(T),
                              width_bytes, height,
                              cudaMemcpyHostToDevice));
    }
    host_is_dirty_ = false;
    device_is_dirty_ = false;  // After copy, both are in sync
}

template<typename T, int Dim>
void DeviceBuffer<T, Dim>::copyToHost() {
    if (Dim == 1) {
        size_t size_bytes = host_storage_->n_elem * host_storage_->row_width * sizeof(T);
        CUDA_CHECK(cudaMemcpy(host_storage_->x.get(), device_ptr_, size_bytes, cudaMemcpyDeviceToHost));
    } else if (Dim == 2) {
        size_t width_bytes = host_storage_->row_width * sizeof(T);
        size_t height = host_storage_->n_elem;
        CUDA_CHECK(cudaMemcpy2D(host_storage_->x.get(), host_storage_->row_width * sizeof(T),
                              device_ptr_, pitch_bytes_,
                              width_bytes, height,
                              cudaMemcpyDeviceToHost));
    }
    host_is_dirty_ = false;
    device_is_dirty_ = false;  // After copy, both are in sync
}

template<typename T, int Dim>
const T* DeviceBuffer<T, Dim>::devicePtr() const noexcept {
    return device_ptr_;
}

template<typename T, int Dim>
size_t DeviceBuffer<T, Dim>::pitch() const noexcept {
    return pitch_bytes_;
}

// Smart synchronization methods - host side
template<typename T, int Dim>
const VecArrayStorage* DeviceBuffer<T, Dim>::h_ptr() const {
    if (device_is_dirty_) {
        // Device has newer data, sync to host
        const_cast<DeviceBuffer*>(this)->copyToHost();
    }
    return host_storage_;
}

template<typename T, int Dim>
VecArrayStorage* DeviceBuffer<T, Dim>::h_ptr() {
    // First ensure we have the latest data
    const_cast<const DeviceBuffer*>(this)->h_ptr();
    // Mark host as dirty since caller can modify it
    host_is_dirty_ = true;
    device_is_dirty_ = false;
    return const_cast<VecArrayStorage*>(host_storage_);
}

// Smart synchronization methods - device side
template<typename T, int Dim>
const T* DeviceBuffer<T, Dim>::d_ptr() const {
    if (host_is_dirty_) {
        // Host has newer data, sync to device
        const_cast<DeviceBuffer*>(this)->copyToDevice();
    }
    return device_ptr_;
}

template<typename T, int Dim>
T* DeviceBuffer<T, Dim>::d_ptr() {
    // First ensure we have the latest data
    const_cast<const DeviceBuffer*>(this)->d_ptr();
    // Mark device as dirty since caller can modify it
    device_is_dirty_ = true;
    host_is_dirty_ = false;
    return device_ptr_;
}

// Explicit template instantiations for the types we need
template class DeviceBuffer<float, 1>;
template class DeviceBuffer<float, 2>;

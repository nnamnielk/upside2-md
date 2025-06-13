#include "device_buffer.h"

// This is the only file that needs to include the CUDA runtime.
#include <cuda_runtime.h>

#include <vector>
#include <iostream>
#include <utility> // For std::swap

// A simple CUDA error-checking macro
static void handle_cuda_error(cudaError_t err, const char *file, int line) {
    if (err != cudaSuccess) {
        std::cerr << "CUDA error in " << file << " at line " << line << ": " << cudaGetErrorString(err) << std::endl;
        exit(EXIT_FAILURE);
    }
}
#define CUDA_CHECK(err) (handle_cuda_error(err, __FILE__, __LINE__))


// --- Private Implementation (pImpl) ---
// The definition of our private struct. All CUDA-specific members live here.
template<typename T>
struct device_buffer<T>::pimpl {
    std::vector<T> host_data_;
    T* device_ptr_ = nullptr;
    size_t size_ = 0;
    bool host_dirty_ = false;
    bool device_dirty_ = false;

    void sync_to_host() {
        if (device_dirty_) {
            CUDA_CHECK(cudaMemcpy(host_data_.data(), device_ptr_, size_ * sizeof(T), cudaMemcpyDeviceToHost));
            device_dirty_ = false;
        }
    }

    void sync_to_device() {
        if (host_dirty_) {
            CUDA_CHECK(cudaMemcpy(device_ptr_, host_data_.data(), size_ * sizeof(T), cudaMemcpyHostToDevice));
            host_dirty_ = false;
        }
    }
};

// --- Public Method Implementations ---
// The constructor now creates the pImpl object.
template<typename T>
device_buffer<T>::device_buffer(size_t size) : pimpl_(new pimpl()) {
    pimpl_->size_ = size;
    pimpl_->host_data_.resize(size);
    CUDA_CHECK(cudaMalloc(&pimpl_->device_ptr_, size * sizeof(T)));
}

// The destructor must be defined here where the pImpl is a complete type.
template<typename T>
device_buffer<T>::~device_buffer() = default;

// Move constructor/assignment are also defined here.
template<typename T>
device_buffer<T>::device_buffer(device_buffer&&) noexcept = default;
template<typename T>
device_buffer<T>& device_buffer<T>::operator=(device_buffer&&) noexcept = default;


template<typename T>
const T* device_buffer<T>::get_host_ptr() {
    pimpl_->sync_to_host();
    return pimpl_->host_data_.data();
}

template<typename T>
T* device_buffer<T>::get_mutable_host_ptr() {
    pimpl_->sync_to_host();
    pimpl_->host_dirty_ = true;
    return pimpl_->host_data_.data();
}

template<typename T>
const T* device_buffer<T>::get_device_ptr() {
    pimpl_->sync_to_device();
    return pimpl_->device_ptr_;
}

template<typename T>
T* device_buffer<T>::get_mutable_device_ptr() {
    pimpl_->sync_to_device();
    pimpl_->device_dirty_ = true;
    return pimpl_->device_ptr_;
}

template<typename T>
size_t device_buffer<T>::get_size() const {
    return pimpl_->size_;
}

template<typename T>
void device_buffer<T>::swap(device_buffer& other) noexcept {
    pimpl_.swap(other.pimpl_);
}

// --- Explicit Template Instantiation ---
// Since the implementation is in a .cpp file, we must tell the compiler
// which versions of the template to build.
template class device_buffer<float>;
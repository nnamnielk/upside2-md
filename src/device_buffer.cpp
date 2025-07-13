#include "device_buffer.h"
#include <vector>
#include <algorithm> // For std::copy

// Private implementation struct
template<typename T>
struct device_buffer<T>::pimpl {
    std::vector<T> host_data;
    std::vector<T> device_data; // Simulates device memory on CPU
    bool host_dirty;
    bool device_dirty;

    pimpl(size_t size) :
        host_data(size),
        device_data(size), // Allocate simulated device memory
        host_dirty(true),
        device_dirty(false) // Initially, host is the source of truth
    {
        // Initialize host_data to zeros
        std::fill(host_data.begin(), host_data.end(), T{});
    }

    // No explicit destructor needed for std::vector
    ~pimpl() = default;
};

// Constructor
template<typename T>
device_buffer<T>::device_buffer(size_t size) :
    pimpl_(new pimpl(size)) {}

// Destructor
template<typename T>
device_buffer<T>::~device_buffer() = default;

// Move Constructor
template<typename T>
device_buffer<T>::device_buffer(device_buffer&& other) noexcept :
    pimpl_(std::move(other.pimpl_)) {}

// Move Assignment Operator
template<typename T>
device_buffer<T>& device_buffer<T>::operator=(device_buffer&& other) noexcept {
    if (this != &other) {
        pimpl_ = std::move(other.pimpl_);
    }
    return *this;
}

// Get const host pointer
template<typename T>
const T* device_buffer<T>::get_host_ptr() {
    if (pimpl_->device_dirty) {
        // Device has the most recent data, copy to host
        std::copy(pimpl_->device_data.begin(), pimpl_->device_data.end(), pimpl_->host_data.begin());
        pimpl_->device_dirty = false;
    }
    pimpl_->host_dirty = false; // Host is now up-to-date
    return pimpl_->host_data.data();
}

// Get mutable host pointer
template<typename T>
T* device_buffer<T>::get_mutable_host_ptr() {
    if (pimpl_->device_dirty) {
        // Device has the most recent data, copy to host
        std::copy(pimpl_->device_data.begin(), pimpl_->device_data.end(), pimpl_->host_data.begin());
        pimpl_->device_dirty = false;
    }
    pimpl_->host_dirty = true; // Host data will be modified
    return pimpl_->host_data.data();
}

// Get const device pointer (simulated)
template<typename T>
const T* device_buffer<T>::get_device_ptr() {
    if (pimpl_->host_dirty) {
        // Host has the most recent data, copy to device
        std::copy(pimpl_->host_data.begin(), pimpl_->host_data.end(), pimpl_->device_data.begin());
        pimpl_->host_dirty = false;
    }
    pimpl_->device_dirty = false; // Device is now up-to-date
    return pimpl_->device_data.data();
}

// Get mutable device pointer (simulated)
template<typename T>
T* device_buffer<T>::get_mutable_device_ptr() {
    if (pimpl_->host_dirty) {
        // Host has the most recent data, copy to device
        std::copy(pimpl_->host_data.begin(), pimpl_->host_data.end(), pimpl_->device_data.begin());
        pimpl_->host_dirty = false;
    }
    pimpl_->device_dirty = true; // Device data will be modified
    return pimpl_->device_data.data();
}

// Get size
template<typename T>
size_t device_buffer<T>::get_size() const {
    return pimpl_->host_data.size();
}

// Swap
template<typename T>
void device_buffer<T>::swap(device_buffer& other) noexcept {
    using std::swap;
    swap(pimpl_, other.pimpl_);
}

// Explicit template instantiation for common types to avoid linker errors
// if device_buffer.cpp is compiled separately from its usage.
template class device_buffer<float>;
template class device_buffer<double>;
template class device_buffer<int>;

#ifndef DEVICE_BUFFER_H
#define DEVICE_BUFFER_H

#include <cstddef> // For size_t
#include <memory>  // For std::unique_ptr

template<typename T>
class device_buffer {
public:
    explicit device_buffer(size_t size);
    ~device_buffer();

    // The pImpl idiom requires us to define the move operations
    device_buffer(device_buffer&&) noexcept;
    device_buffer& operator=(device_buffer&&) noexcept;

    // We explicitly delete the copy operations
    device_buffer(const device_buffer&) = delete;
    device_buffer& operator=(const device_buffer&) = delete;

    const T* get_host_ptr();
    T* get_mutable_host_ptr();
    const T* get_device_ptr();
    T* get_mutable_device_ptr();
    size_t get_size() const;

    void swap(device_buffer& other) noexcept;

private:
    struct pimpl; // Forward-declare the private implementation struct
    std::unique_ptr<pimpl> pimpl_; // A single pointer to the implementation
};

// Free swap function for idiomatic C++
template<typename T>
void swap(device_buffer<T>& a, device_buffer<T>& b) noexcept {
    a.swap(b);
}

#endif
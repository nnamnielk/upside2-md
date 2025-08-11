#ifndef DEVICE_BUFFER_H
#define DEVICE_BUFFER_H

#include <cstddef>

// Forward declarations to avoid including CUDA headers here
struct VecArrayStorage;
struct VecArray;

template<typename T, int Dim>
class DeviceBuffer {
private:
    VecArrayStorage* host_storage_;
    T* device_ptr_;
    size_t pitch_bytes_;
    mutable bool host_is_dirty_;
    mutable bool device_is_dirty_;

public:
    explicit DeviceBuffer(const VecArrayStorage& host);
    ~DeviceBuffer();

    DeviceBuffer(DeviceBuffer&& other) noexcept;
    DeviceBuffer& operator=(DeviceBuffer&& other) noexcept;

    // Delete copy operations
    DeviceBuffer(const DeviceBuffer&) = delete;
    DeviceBuffer& operator=(const DeviceBuffer&) = delete;

    void copyToDevice();
    void copyToHost();

    const T* devicePtr() const noexcept;
    size_t   pitch()     const noexcept;
    
    const VecArrayStorage* h_ptr() const;
    VecArrayStorage* h_ptr();
    
    const T* d_ptr() const;
    T* d_ptr();
};

#endif

#ifndef DEVICE_BUFFER_H
#define DEVICE_BUFFER_H

#include <cstddef>

// Forward declarations to avoid including CUDA headers here
struct VecArrayStorage;
struct VecArray;

template<typename T, int Dim>
class DeviceBuffer {
private:
    const VecArrayStorage* host_storage_;
    T* device_ptr_;
    size_t pitch_bytes_;

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
    
    // Host view accessor - return pointer to VecArrayStorage (which has implicit VecArray conversion)
    const VecArrayStorage* h_ptr() const { return host_storage_; }
};

#endif

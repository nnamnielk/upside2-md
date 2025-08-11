#include "device_utils.h"

#ifdef __CUDACC__
// Global device properties definition
cudaDeviceProp g_device_prop;
bool g_device_prop_initialized = false;
#endif

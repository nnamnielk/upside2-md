cmake_minimum_required(VERSION 3.16)
project(CoordNodeTests)

# Use same compiler settings as main project
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -g -O2 -Wall")

option(USE_CUDA "Enable CUDA acceleration" ON)

if(USE_CUDA)
    enable_language(CUDA)
    find_package(CUDAToolkit REQUIRED)
    include_directories(${CUDAToolkit_INCLUDE_DIRS})
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -DUSE_CUDA")
endif()

# Find dependencies
find_package(Eigen3 3.3 REQUIRED CONFIG)

# Fetch Google Test
include(FetchContent)
FetchContent_Declare(
  googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG release-1.12.1
)
# For Windows: Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

# Fetch nlohmann/json
FetchContent_Declare(
  nlohmann_json
  GIT_REPOSITORY https://github.com/nlohmann/json.git
  GIT_TAG v3.11.2
)
FetchContent_MakeAvailable(nlohmann_json)

# Include directories from main project
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/../src)

# Find and link upside library
find_library(UPSIDE_LIB upside PATHS "${CMAKE_CURRENT_SOURCE_DIR}/../obj")
if(NOT UPSIDE_LIB)
    message(FATAL_ERROR "libupside.so not found. Run ../install.sh first.")
endif()

# Additional libraries that upside depends on
find_package(HDF5 REQUIRED COMPONENTS C)
find_package(OpenMP REQUIRED)

# Create nodes executable
add_executable(nodes src/nodes.cpp)

target_link_libraries(nodes PRIVATE 
    gtest_main
    gtest
    nlohmann_json::nlohmann_json
    ${UPSIDE_LIB}
    Eigen3::Eigen
    ${HDF5_LIBRARIES}
    OpenMP::OpenMP_CXX
    pthread
)

if(USE_CUDA)
    target_link_libraries(nodes PRIVATE CUDA::cudart)
endif()

target_include_directories(nodes PRIVATE ${HDF5_INCLUDE_DIRS})

# Enable testing and discover tests
enable_testing()
include(GoogleTest)
gtest_discover_tests(nodes)

# Create hdf5_tester executable
add_executable(hdf5_tester src/hdf5_tester.cpp)

target_link_libraries(hdf5_tester PRIVATE 
    gtest
    ${UPSIDE_LIB}
    Eigen3::Eigen
    ${HDF5_LIBRARIES}
    OpenMP::OpenMP_CXX
    pthread
)

if(USE_CUDA)
    target_link_libraries(hdf5_tester PRIVATE CUDA::cudart)
endif()

target_include_directories(hdf5_tester PRIVATE ${HDF5_INCLUDE_DIRS})

gtest_discover_tests(hdf5_tester)

# Manual test targets for specific categories
add_test(NAME CoordNodeCPUTests 
         COMMAND nodes --gtest_filter="*CPU*")
add_test(NAME CoordNodeGPUTests 
         COMMAND nodes --gtest_filter="*GPU*")
add_test(NAME CoordNodeComparisonTests 
         COMMAND nodes --gtest_filter="*CPUvsGPU*")
add_test(NAME GoldenMasterGeneration
         COMMAND nodes --gtest_filter="*GenerateGolden*")

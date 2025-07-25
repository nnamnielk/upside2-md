cmake_minimum_required(VERSION 3.16) # Eigen3 find_package benefits from newer versions
project(PairlistUnitTest)

# === Settings from main project's CMakeLists.txt ===
set(ARCH "native" CACHE STRING "architecture to use for -march flag to compiler")
find_package(OpenMP QUIET) # From main project

set(PROJECT_DEBUG_FLAGS "-g") # Renamed to avoid conflict if CMAKE_BUILD_TYPE sets its own
set(PROJECT_GPROF_FLAGS "-pg")
set(PROJECT_OMP_FLAGS "") # Initialize
if(OpenMP_FOUND)
    set(PROJECT_OMP_FLAGS "${OpenMP_CXX_FLAGS}")
endif()
set(PROJECT_DEFINES "-DR123_NO_SINCOS -Drestrict=__restrict__ -DNDEBUG") # NDEBUG might affect Catch2 assertions if not handled.
set(PROJECT_OPT "-Og -fno-omit-frame-pointer -march=${ARCH}")
set(PROJECT_WARN "-pedantic -Wall -Wno-strict-overflow -Wno-unused-function -Wno-unknown-pragmas")
set(PROJECT_CXX_STANDARD "-std=c++11")

# Combine all flags
# We are explicitly setting many flags here as per the main project.
set(CMAKE_CXX_FLAGS "${PROJECT_OMP_FLAGS} ${PROJECT_DEBUG_FLAGS} ${PROJECT_CXX_STANDARD} ${PROJECT_DEFINES} ${PROJECT_OPT} ${PROJECT_WARN} ${PROJECT_GPROF_FLAGS}")
# Linker flags from main project (optional for compile flags request, but good for consistency if needed)
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} ${PROJECT_OMP_FLAGS} ${PROJECT_GPROF_FLAGS}")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} ${PROJECT_OMP_FLAGS} ${PROJECT_GPROF_FLAGS}")

# === Eigen3 ===
find_package(Eigen3 3.3 REQUIRED CONFIG)

# === Catch2 ===
include(FetchContent)
FetchContent_Declare(
  Catch2
  GIT_REPOSITORY https://github.com/catchorg/Catch2.git
  GIT_TAG v2.13.10 # Stable Catch2 v2.x release compatible with C++11
)
FetchContent_MakeAvailable(Catch2)

# === Required Source Files ===
set(REQUIRED_SRC
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/h5_support.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/deriv_engine.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/state_logger.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/timing.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/spline.cpp"
)

# === Test Executable ===
add_executable(testbridge testbridge.cpp ${REQUIRED_SRC})

# Add the compile definition for test accessors HERE:
target_compile_definitions(testbridge PRIVATE TEST_HOOKS)

# === Include Directories ===
target_include_directories(testbridge PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../src" # Path to Float4.h, interaction_graph.h etc.
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/include" # Include subdirectory
    "$catch2_SOURCE_DIR/include" # Catch2 include directory
)

# === Link Libraries ===
target_link_libraries(testbridge PRIVATE
    Catch2::Catch2
    Eigen3::Eigen      # For Eigen
    stdc++             # Standard C++ library
)
if(OpenMP_FOUND)
    target_link_libraries(testbridge PRIVATE OpenMP::OpenMP_CXX)
endif()

# === Enable Testing with CTest ===
enable_testing()
add_test(NAME PairlistComputationTests COMMAND testbridge)

# === HDF5 Support ===
find_package(HDF5 COMPONENTS C QUIET)
if(HDF5_FOUND)
  target_include_directories(testbridge PRIVATE ${HDF5_C_INCLUDE_DIRS})
  target_link_libraries(testbridge PRIVATE ${HDF5_C_LIBRARIES})
endif()

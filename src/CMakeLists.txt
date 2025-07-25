cmake_minimum_required(VERSION 3.8)
project(upside CXX C)

option(USE_CUDA "Enable CUDA acceleration" ON)
option(DEBUG "Enable debug build" ON)

if(USE_CUDA)
    enable_language(CUDA)
    find_package(CUDA REQUIRED)
    include_directories("${CUDA_INCLUDE_DIRS}")
    
    message(STATUS "CUDA Compiler: ${CMAKE_CUDA_COMPILER}")
    message(STATUS "CUDA Version: ${CMAKE_CUDA_COMPILER_VERSION}")
    set(CMAKE_CUDA_ARCHITECTURES 86)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -DUSE_CUDA")
    set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -D__CUDACC__")
endif()

set (CMAKE_MODULE_PATH "../cmake;${CMAKE_MODULE_PATH}")
find_package(HDF5 REQUIRED COMPONENTS C)
find_package(OpenMP QUIET)

set(ARCH "native" CACHE STRING "architecture to use for -march flag to compiler")

if(DEBUG)
    set (OPT "-Og -g -fno-omit-frame-pointer -march=${ARCH}")
    set(GPROF_FLAGS "-pg")
else()
    set(GPROF_FLAGS "")
    set (OPT "-O3 --fast-math -fno-omit-frame-pointer -march=${ARCH}")
endif()

set (OMP_FLAGS "${OpenMP_CXX_FLAGS}") # "-fsanitize=address") #

# Fix the restrict keyword issue - map it to __restrict__ which is supported by GCC/Clang
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    set (DEFINES "-DR123_NO_SINCOS -Drestrict=__restrict__ -DNDEBUG")
elseif(CMAKE_CXX_COMPILER_ID MATCHES "MSVC")
    set (DEFINES "-DR123_NO_SINCOS -Drestrict=__restrict -DNDEBUG")
else()
    # For other compilers, remove restrict entirely
    set (DEFINES "-DR123_NO_SINCOS -Drestrict= -DNDEBUG")
endif()

set (WARN "-pedantic -Wall -Wno-strict-overflow -Wno-unused-function -Wno-unknown-pragmas")

set (CMAKE_CXX_FLAGS "${OMP_FLAGS} ${CMAKE_CXX_FLAGS} -std=c++11 ${DEFINES} ${OPT} ${WARN} ${GPROF_FLAGS}" )

if(USE_CUDA)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -DUSE_CUDA")
    set(CMAKE_CUDA_FLAGS "${CMAKE_CUDA_FLAGS} -D__CUDACC__")
endif()

set (CMAKE_LD_FLAGS "${OMP_FLAGS} ${CMAKE_LD_FLAGS} ${GPROF_FLAGS}" )
include_directories(SYSTEM "include")

set (ENGINE_SRC
main.cpp
environment.cpp
hbond.cpp
rotamer.cpp
placement.cpp
rama_map_pot.cpp
coord_operator.cpp
coord_basic.cpp
coord_const.cpp
coord_map.cpp
spline.cpp
spring.cpp
tension.cpp
sigmoid_energy.cpp
deriv_engine.cpp
sidechain_radial.cpp
backbone_steric.cpp
eig.cpp
membrane_potential.cpp
surface.cpp
timing.cpp
thermostat.cpp
h5_support.cpp
state_logger.cpp
monte_carlo_sampler.cpp
device_buffer.cpp)

if(USE_CUDA)
# Add the new .cu file to the source list
list(APPEND ENGINE_SRC interaction_graph.cu)
endif()

add_executable (upside ${ENGINE_SRC})

INCLUDE_DIRECTORIES (${HDF5_INCLUDE_DIRS})
target_link_libraries(upside stdc++ ${HDF5_LIBRARIES})

find_package(Eigen3 REQUIRED)
include_directories(SYSTEM ${EIGEN3_INCLUDE_DIR})

add_library(upside_calculation SHARED
engine_c_library.cpp
${ENGINE_SRC})

set_target_properties(upside_calculation PROPERTIES
COMPILE_FLAGS "-DPARAM_DERIV"
OUTPUT_NAME "upside")

target_link_libraries(upside_calculation stdc++ ${HDF5_LIBRARIES})

if(USE_CUDA)
target_link_libraries(upside ${CUDA_LIBRARIES})
target_link_libraries(upside_calculation ${CUDA_LIBRARIES})
endif()

add_executable(compute_rotamer_centers generate_from_rotamer.cpp compute_rotamer_centers.cpp h5_support.cpp)
target_link_libraries(compute_rotamer_centers stdc++ m ${HDF5_LIBRARIES})
set_target_properties(compute_rotamer_centers PROPERTIES EXCLUDE_FROM_ALL 1)

add_executable(compute_rotamer_pos generate_from_rotamer.cpp compute_rotamer_pos.cpp h5_support.cpp)
target_link_libraries(compute_rotamer_pos stdc++ m ${HDF5_LIBRARIES})
set_target_properties(compute_rotamer_pos PROPERTIES EXCLUDE_FROM_ALL 1)
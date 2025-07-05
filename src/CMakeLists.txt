cmake_minimum_required(VERSION 3.5)
project(upside CXX C)

option(DEBUG "Enable debug build" OFF)
# option(USE_CUDA "Enable CUDA acceleration" ON)

if(APPLE AND CMAKE_SYSTEM_PROCESSOR MATCHES "arm64")
    message(STATUS "Detected ARM Mac (M1/M2/M3), using CMakeLists_arm.txt")
    include(${CMAKE_SOURCE_DIR}/CMakeLists_arm.txt)
else()
    message(STATUS "Using default CMakeLists_x86.txt for x86_64")
    include(${CMAKE_SOURCE_DIR}/CMakeLists_x86.txt)
endif()

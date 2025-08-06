cmake_minimum_required(VERSION 3.5)
project(upside CXX C)

option(DEBUG "Enable debug build" ON)
# option(USE_CUDA "Enable CUDA acceleration" ON)

# Detect ARM architecture on any platform (Linux, macOS)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
    message(STATUS "Detected ARM architecture (${CMAKE_SYSTEM_PROCESSOR}), using CMakeLists_arm.txt")
    include(${CMAKE_SOURCE_DIR}/CMakeLists_arm.txt)
else()
    message(STATUS "Detected x86_64 architecture, using CMakeLists_x86.txt")
    include(${CMAKE_SOURCE_DIR}/CMakeLists_x86.txt)
endif()

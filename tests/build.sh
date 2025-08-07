#!/bin/bash
set -e

echo "Building CoordNode test suite with Google Test..."

# Ensure main project is built first
if [ ! -f "../obj/libupside.so" ]; then
    echo "Building main project first..."
    cd .. && ./install.sh && cd tests/
fi

# Create build directory
mkdir -p obj
cd obj

# Configure with CMake
cmake .. \
    -DEIGEN3_INCLUDE_DIR="$EIGEN_HOME" \
    -DCMAKE_BUILD_TYPE=Debug

# Build
make -j$(nproc)

echo ""
echo "Build complete!"
echo ""
echo "Usage:"
echo "  Run all tests:           cd obj && ctest --output-on-failure"
echo "  Run GTest directly:      cd obj && ./nodes"
echo "  Run CPU tests only:      cd obj && ./nodes --gtest_filter='*CPU*'"
echo "  Generate golden masters: cd obj && ./nodes --gtest_filter='*GenerateGolden*'"
echo "  List available tests:    cd obj && ./nodes --gtest_list_tests"
echo ""

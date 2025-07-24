#!/bin/bash

# Initialize conda
source /opt/conda/etc/profile.d/conda.sh

# Activate project environment
conda activate upside2-env 2>/dev/null || echo "Warning: upside2-env not found, using base"

# Set project environment variables
export UPSIDE_HOME="/upside2-md"
export PATH="$UPSIDE_HOME/py:$UPSIDE_HOME/obj:$PATH"
export PYTHONPATH="$UPSIDE_HOME/py:$PYTHONPATH"

# Apply dev configuration
sed -i 's|export MY_PYTHON=.*|export MY_PYTHON=/opt/conda|' /upside2-md/source_x86
sed -i 's|export EIGEN_HOME=.*|export EIGEN_HOME=/usr/include/eigen3|' /upside2-md/source_x86
sed -i 's/option(DEBUG "Enable debug build" OFF)/option(DEBUG "Enable debug build" ON)/' /upside2-md/src/CMakeLists_x86.txt
sed -i 's|cmake ../src/  -DEIGEN3_INCLUDE_DIR=$EIGEN_HOME|cmake ../src/  -DEIGEN3_INCLUDE_DIR=$EIGEN_HOME -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache|' /upside2-md/install.sh

# Rebuild in development environment
if command -v gdb >/dev/null 2>&1; then
    echo "Development environment detected, ensuring fresh build..."
    cd /upside2-md && ./install.sh
fi

# Run command or start interactive shell
if [ $# -eq 0 ]; then
    exec bash
else
    exec "$@"
fi

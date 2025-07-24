#!/bin/bash
# .devcontainer/post-create.sh

# Exit immediately if a command exits with a non-zero status.
set -e

echo "--- Starting Post-Create Setup ---"

# --- Build the C++ Code ---
echo "Setting up build environment for C++ compilation..."
export EIGEN_HOME=/usr/include/eigen3

sed -i "s|export MY_PYTHON=.*|export MY_PYTHON=/opt/conda|" /upside2-md/source_x86
sed -i "s|export EIGEN_HOME=.*|export EIGEN_HOME=/usr/include/eigen3|" /upside2-md/source_x86
sed -i 's/option(DEBUG "Enable debug build" OFF)/option(DEBUG "Enable debug build" ON)/' /upside2-md/src/CMakeLists.txt
# Only add ccache if not already present to avoid recursive replacement
if ! grep -q "DCMAKE_C_COMPILER_LAUNCHER=ccache" /upside2-md/install.sh; then
    sed -i "s|cmake ../src/  -DEIGEN3_INCLUDE_DIR=\$EIGEN_HOME|cmake ../src/  -DEIGEN3_INCLUDE_DIR=\$EIGEN_HOME -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache|" /upside2-md/install.sh
fi

# Initialize and configure ccache
echo "Initializing ccache..."
export CCACHE_DIR=/upside2-md/.ccache
export CCACHE_MAXSIZE=12G
ccache --set-config=max_size=12G
ccache --set-config=cache_dir=/upside2-md/.ccache
ccache --zero-stats

echo "Building Upside C++ code..."
sudo /upside2-md/install.sh

# Fix ownership of build directory so regular user can write to it
echo "Fixing ownership of build directory..."
sudo chown -R user:user /upside2-md/obj

# Verify ccache is working
echo "Ccache status after build:"
ccache --show-stats

# --- Generate Doxygen Documentation ---
echo "Generating Doxygen documentation..."
doxygen /upside2-md/Doxyfile

echo "--- Post-Create Setup Complete ---"

# --- Configure Shell for Interactive Use ---
echo "Configuring .bashrc for interactive shells..."
echo '' >> ~/.bashrc
echo '# >>> conda initialize >>>' >> ~/.bashrc
echo '# !! Contents within this block are managed by '\''conda init'\'' !!' >> ~/.bashrc
echo '__conda_setup="$('\'/opt/conda/bin/conda\'' '\''shell.bash'\'' '\''hook'\'' 2> /dev/null)"' >> ~/.bashrc
echo 'if [ $? -eq 0 ]; then' >> ~/.bashrc
echo '    eval "$__conda_setup"' >> ~/.bashrc
echo 'else' >> ~/.bashrc
echo '    if [ -f "/opt/conda/etc/profile.d/conda.sh" ]; then' >> ~/.bashrc
echo '        . "/opt/conda/etc/profile.d/conda.sh"' >> ~/.bashrc
echo '    else' >> ~/.bashrc
echo '        export PATH="/opt/conda/bin:$PATH"' >> ~/.bashrc
echo '    fi' >> ~/.bashrc
echo 'fi' >> ~/.bashrc
echo 'unset __conda_setup' >> ~/.bashrc
echo '# <<< conda initialize <<<' >> ~/.bashrc
echo '' >> ~/.bashrc
echo '# Activate the default conda environment' >> ~/.bashrc
echo 'conda activate upside2-env' >> ~/.bashrc

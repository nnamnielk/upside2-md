#!/bin/bash

# Initialize conda
source /opt/conda/etc/profile.d/conda.sh

# Activate project environment
conda activate upside2-env 2>/dev/null || echo "Warning: upside2-env not found, using base"

# Set project environment variables
export UPSIDE_HOME="/upside2-md"
export PATH="$UPSIDE_HOME/py:$UPSIDE_HOME/obj:$PATH"
export PYTHONPATH="$UPSIDE_HOME/py:$PYTHONPATH"

# Set ccache environment variables
export CCACHE_DIR="/upside2-md/.ccache"
export CCACHE_MAXSIZE="12G"

# Run command or start interactive shell
if [ $# -eq 0 ]; then
    exec bash
else
    exec "$@"
fi

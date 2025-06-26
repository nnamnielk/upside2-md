#!/bin/bash

# Default SBATCH settings
JOB_NAME="upside2_md_sif"
TIME="4:00:00"
PARTITION="cpu"
GRES="cpu:1"
MEM="16gb"
ACCOUNT="pi-trsosnic"

# --- Help Function ---
show_help() {
cat << EOF
Usage: $0 --executable <path> [options]

This script runs a command inside the upside2-md.sif Singularity container
using sbatch for job submission on a Slurm cluster.

Required:
  --executable <path>   Path to the executable to run inside the container.

Options:
  --scripts-to-mount <path>
                        Path to a script or directory to mount into the container's
                        /upside2-md/data/ directory. Can be specified multiple times.
  --args "<args>"       Quoted string of arguments to pass to the executable.
  --job-name <name>     Name of the Slurm job. (Default: ${JOB_NAME})
  --time <hh:mm:ss>     Wall time for the job. (Default: ${TIME})
  --partition <name>    Slurm partition to use. (Default: ${PARTITION})
  --gres <spec>         Generic resource request. (Default: ${GRES})
  --mem <size>          Memory request (e.g., 16gb). (Default: ${MEM})
  --account <name>      Account to charge for the job. (Default: ${ACCOUNT})
  -h, --help            Display this help message and exit.
EOF
}

# --- Command-Line Argument Parsing ---
MOUNTS=()
EXECUTABLE=""
EXEC_ARGS=""

# If no arguments are provided, show help and exit.
if [ $# -eq 0 ]; then
    show_help
    exit 1
fi

# Use getopt to parse arguments
OPTS=$(getopt -o 'h' --long "help,scripts-to-mount:,executable:,args:,job-name:,time:,partition:,gres:,mem:,account:" -n "$0" -- "$@")
if [ $? != 0 ]; then echo "Failed parsing options." >&2; exit 1; fi
eval set -- "$OPTS"

while true; do
  case "$1" in
    -h|--help ) show_help; exit 0 ;;
    --scripts-to-mount ) MOUNTS+=("$2"); shift 2 ;;
    --executable ) EXECUTABLE="$2"; shift 2 ;;
    --args ) EXEC_ARGS="$2"; shift 2 ;;
    --job-name ) JOB_NAME="$2"; shift 2 ;;
    --time ) TIME="$2"; shift 2 ;;
    --partition ) PARTITION="$2"; shift 2 ;;
    --gres ) GRES="$2"; shift 2 ;;
    --mem ) MEM="$2"; shift 2 ;;
    --account ) ACCOUNT="$2"; shift 2 ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

# --- SBATCH Header ---
# This section is interpreted by sbatch
#SBATCH --job-name=${JOB_NAME}
#SBATCH --time=${TIME}
#SBATCH --output=${JOB_NAME}_%j.txt
#SBATCH --error=${JOB_NAME}_%j.err
#SBATCH --account=${ACCOUNT}
#SBATCH --partition=${PARTITION}
#SBATCH --gres=${GRES}
#SBATCH --mem=${MEM}

# --- Script Logic ---
node=$(hostname -s)
user=$(whoami)
cluster="midway3"

echo "Job started on ${node} at $(date)"
echo "User: ${user}"
echo "Cluster: ${cluster}"

# Load Singularity module
module load singularity

# Construct bind mounts
BIND_PATHS=""
for mount in "${MOUNTS[@]}"; do
    if [ -e "$mount" ]; then
        # Mount to /upside2-md/data/<basename>
        BIND_PATHS+="--bind $mount:/upside2-md/data/$(basename "$mount") "
    else
        echo "Warning: Path '$mount' not found, skipping."
    fi
done

# Check if executable is provided
if [ -z "$EXECUTABLE" ]; then
    echo "Error: --executable flag is required."
    echo
    show_help
    exit 1
fi

# Run the command in Singularity
echo "Executing command: $EXECUTABLE $EXEC_ARGS"
singularity exec ${BIND_PATHS} upside2-md.sif bash -c "source /home/user/.bashrc && $EXECUTABLE $EXEC_ARGS"

echo "Job finished at $(date)"

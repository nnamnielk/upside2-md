#!/bin/bash
#SBATCH --job-name=jupyter_notebook
#SBATCH --time=05:00:00
#SBATCH --output=jupyter_notebook_%j.txt
#SBATCH --error=jupyter_notebook_%j.err
#SBATCH --account=pi-<group>      # <-- User needs to fill this in
#SBATCH --partition=<partition>   # <-- User needs to select a partition (e.g., broadwl, shared)
#SBATCH --mem=16gb
#
# To request a GPU, uncomment the following lines and set an appropriate partition:
# #SBATCH --partition=gpu
# #SBATCH --gres=gpu:1

# --- Environment Setup ---
# Assign a random port between 8000 and 9000
PORT_NUM=$(shuf -i8000-9000 -n1)
NODE=$(hostname -s)
USER=$(whoami)
CLUSTER="midway3"
IMAGE_NAME="upside2-ipy.sif"

# --- User Instructions ---
# Print tunneling instructions to the output file
echo -e "
===================================================================================
Jupyter Notebook is running on node: ${NODE}
To connect, you first need to create an SSH tunnel from your local machine.

Run the following command in a new terminal on your local machine:
ssh -N -f -L ${PORT_NUM}:${NODE}:${PORT_NUM} ${USER}@${CLUSTER}.rcc.uchicago.edu

Then, open a web browser on your local machine and navigate to:
http://localhost:${PORT_NUM}/

Check the jupyter_notebook_${SLURM_JOB_ID}.err file for the Jupyter token if required.
===================================================================================
"

# --- Execution ---
# Load the Singularity module
module load singularity

# Define the definition file name
DEF_FILE="upside2-ipy.def"

# Build the singularity image if it doesn't exist or if the definition file is newer
if [ ! -f "${IMAGE_NAME}" ] || [ "${DEF_FILE}" -nt "${IMAGE_NAME}" ]; then
  echo "Building Singularity image ${IMAGE_NAME} from ${DEF_FILE}..."
  singularity build --force "${IMAGE_NAME}" "${DEF_FILE}"
fi

# Execute the Jupyter Lab server in the container
# It binds the current directory to /data inside the container.
# Add more --bind flags if you need to mount other directories.
singularity exec --bind $PWD:/data ${IMAGE_NAME} jupyter lab --no-browser --ip=${NODE} --port=${PORT_NUM}

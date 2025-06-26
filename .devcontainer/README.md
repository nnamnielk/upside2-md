# Using Upside2 with Docker

This guide provides instructions for running the Upside2 application using Docker. This is the recommended method for most users as it provides a consistent, isolated environment without requiring manual dependency installation.

## Prerequisites

Before you begin, make sure you have Docker installed on your system. You can download it from the official [Docker website](https://www.docker.com/get-started).

## Simplified Installation with `docker_up.sh` (Recommended for New Users)

For a fully automated setup, you can use the `docker_up.sh` script included in this repository. This script will:
1.  Check if Docker is installed and, if not, attempt to install it for your operating system (Linux, macOS, or Windows).
2.  Pull the latest `oliverkleinmann/upside2-md` Docker image.
3.  Provide a simple way to run the container with your custom scripts.

**How to use it:**

1.  **Make the script executable:**
    ```bash
    chmod +x docker_up.sh
    ```

2.  **Run the installation:**
    ```bash
    ./docker_up.sh
    ```
    This will ensure Docker is installed and pull the necessary image. If the image is already present, it will ask if you want to pull it again.

3.  **Run the container with your scripts:**
    To run the container and mount one or more local directories into the container's `/upside2-md/scripts/` directory, use the `-v` flag. You can use the flag multiple times.

    *   **Mount a single directory:**
        ```bash
        ./docker_up.sh -v ./my_scripts
        ```
        This will mount `./my_scripts` to `/upside2-md/scripts/my_scripts` inside the container.

    *   **Mount multiple directories:**
        ```bash
        ./docker_up.sh -v ./my_scripts -v ./another_set_of_scripts
        ```
        This will mount `./my_scripts` to `/upside2-md/scripts/my_scripts` and `./another_set_of_scripts` to `/upside2-md/scripts/another_set_of_scripts`.

    This will launch an interactive session inside the container with your files ready to use.

## Manual Docker Setup

To install and manage Docker manually, you can download it from the [official Docker website](https://www.docker.com/get-started). Once Docker is installed, follow the steps below.

### Getting the Docker Image

#### Option 1: Pull from Docker Hub (Recommended)

For most users, the easiest way to get started is to pull the pre-built image from Docker Hub:

```bash
docker pull oliverkleinmann/upside2-md
```

This image is regularly updated and contains all the necessary dependencies to run Upside2 simulations.

### Option 2: Build from Source

Building the image from source is only recommended if you need to add new dependencies that are not included in the default image. If you do add dependencies, please consider contributing by committing your changes to the `environment.yml` or `Dockerfile` and submitting a pull request on GitHub.

To build the image from source:
```bash
docker build -t upside2 https://github.com/sosnicklab/upside2-md.git
```

## Running the Container

### Non-Interactive Mode

To run a script inside the container and see the output, you can use non-interactive mode. For example, to run one of the example scripts:

```bash
docker run --rm oliverkleinmann/upside2-md python example/01.GettingStarted/0.run.py
```
The container will execute the command and then exit.

### Interactive Mode

For an interactive session inside the container, which is useful for exploration and running multiple commands:

```bash
docker run -it --rm oliverkleinmann/upside2-md
```
This command does the following:
*   `docker run`: Starts a new container.
*   `-it`: Opens an interactive terminal session.
*   `--rm`: Automatically removes the container when you exit.
*   `oliverkleinmann/upside2-md`: The name of the image to use.

### Mounting Custom Scripts

If you are not using the `docker_up.sh` script, you can mount a directory of your own custom C++ scripts or other files into the container. This is useful for running your own c++ code within the container's pre-configured environment.

```bash
docker run -it --rm \
  -v "/path/to/your/scripts":/scripts \
  oliverkleinmann/upside2-md
```
Replace `/path/to/your/scripts` with the actual path to your scripts directory on your local machine. Your scripts will then be available inside the container at the `/scripts` directory.

## C++ Development

For C++ development, the expected IDE is VS Code with the Dev Containers extension.

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/sosnicklab/upside2-md.git
    cd upside2-md
    ```

2.  **Open in VS Code and Reopen in Container:**
    Open the `upside2-md` folder in VS Code. It will detect the `.devcontainer` configuration and prompt you to "Reopen in Container". This will build the development environment and mount your local repository files into it.

3.  **Configuring Other IDEs:**
    Support for other IDEs can be configured by modifying the `.devcontainer/devcontainer.json` file.

## Using Upside2 with Singularity on a Slurm Cluster

For users on HPC clusters that use the Slurm workload manager, this repository provides scripts to run jobs inside a Singularity container.

### Prerequisites

-   Singularity is installed on the cluster.
-   You have access to a Slurm cluster.

### Getting the Singularity Image

The `sbatch` scripts in this repository require a Singularity image file named `upside2-md.sif`.

#### Base Image (for `sbatch_runner.sh`)

You can pull the base image directly from Docker Hub. This image is suitable for running general-purpose jobs with `sbatch_runner.sh`.

```bash
singularity pull docker://oliverkleinmann/upside2-md
```

This command downloads the latest version of the Docker image and converts it into a Singularity Image File (`.sif`). The resulting file will be named `upside2-md_latest.sif`. You should rename it for convenience:

```bash
mv upside2-md_latest.sif upside2-md.sif
```

#### Jupyter-Enabled Image (for `sbatch_jupyter.sh`)

To run Jupyter Lab using `sbatch_jupyter.sh`, you need to extend the base image to include Jupyter and other Python dependencies. A definition file, `upside2-ipy.def`, is provided for this purpose.

1.  **Ensure you have the base `upside2-md.sif` image first.**
2.  **Build the extended image using the definition file:**

    ```bash
    sudo singularity build upside2-ipy.sif upside2-ipy.def
    ```
3.  **Rename the final image to `upside2-md.sif`** to be compatible with the `sbatch_jupyter.sh` script, or modify the script to point to `upside2-ipy.sif`. For simplicity, we'll rename it:

    ```bash
    # Back up the old image if you want to keep it
    # mv upside2-md.sif upside2-md-base.sif 
    mv upside2-ipy.sif upside2-md.sif
    ```

Now you have the required `upside2-md.sif` file in your directory and can proceed to submit jobs.

### General Job Submission with `sbatch_runner.sh`

The `sbatch_runner.sh` script is a general-purpose tool for submitting any command to the Slurm scheduler to be run inside the Singularity container.

**Usage:**

To use the script, you submit it with `sbatch`. You must provide an executable to run.

```bash
sbatch sbatch_runner.sh --executable /path/to/your/executable --args "arguments for executable"
```

**Options:**

The script accepts several command-line arguments to customize the Slurm job and the container environment.

*   `--executable <path>`: **(Required)** Path to the executable to run inside the container.
*   `--scripts-to-mount <path>`: Path to a script or directory to mount into the container's `/upside2-md/data/` directory. Can be specified multiple times.
*   `--args "<args>"`: Quoted string of arguments to pass to the executable.
*   `--job-name <name>`: Name of the Slurm job. (Default: `upside2_md_sif`)
*   `--time <hh:mm:ss>`: Wall time for the job. (Default: `4:00:00`)
*   `--partition <name>`: Slurm partition to use. (Default: `cpu`)
*   `--gres <spec>`: Generic resource request. (Default: `cpu:1`)
*   `--mem <size>`: Memory request (e.g., `16gb`). (Default: `16gb`)
*   `--account <name>`: Account to charge for the job. (Default: `pi-trsosnic`)

### Running Jupyter Lab with `sbatch_jupyter.sh`

The `sbatch_jupyter.sh` script is designed to launch a Jupyter Lab session as a Slurm job.

**Setup:**

Before submitting, you **must** edit the script to set your account and partition:

```bash
#SBATCH --account=pi-<group>      # <-- User needs to fill this in
#SBATCH --partition=<partition>   # <-- User needs to select a partition (e.g., broadwl, shared)
```

To request a GPU, you can uncomment the `--gres=gpu:1` line and select a GPU partition.

**Submitting the Job:**

```bash
sbatch sbatch_jupyter.sh
```

**Connecting to Jupyter:**

1.  Once the job starts, check the output file `jupyter_notebook_<job_id>.txt`. It will contain the node the job is running on and the port number.
2.  Create an SSH tunnel from your local machine to the cluster node. The command will be printed in the output file, but it will look like this:
    ```bash
    ssh -N -f -L <PORT>:<NODE>:<PORT> <USER>@midway3.rcc.uchicago.edu
    ```
3.  Open a web browser on your local machine and navigate to: `http://localhost:<PORT>/`
4.  If prompted for a token, check the job's error file: `jupyter_notebook_<job_id>.err`.

## Frequently Asked Questions (FAQ)

**Q: My project has a dependency that isn't included in the Docker/Singularity image. What should I do?**

**A:** You have two main options:

1.  **Extend the Image (Recommended for personal use):**
    You can create a new `Dockerfile` or Singularity definition file that uses the `oliverkleinmann/upside2-md` image as its base and adds your required dependencies. This is the best approach for project-specific needs.

    *   **For Docker:** Create a `Dockerfile` like this:
        ```Dockerfile
        FROM oliverkleinmann/upside2-md
        RUN conda install -y your-dependency
        ```
        Then build it: `docker build -t my-custom-upside2 .`

    *   **For Singularity:** Create a `.def` file similar to `upside2-ipy.def` to add your packages.

2.  **Contribute to the Main Image:**
    If you believe the dependency would be beneficial for many other users, please consider contributing to the project. You can do this by:
    *   Forking the [upside2-md repository](https://github.com/sosnicklab/upside2-md).
    *   Adding the dependency to the `environment.yml` file.
    *   Submitting a pull request with your changes.

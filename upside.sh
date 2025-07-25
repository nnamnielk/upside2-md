#!/bin/bash

# upside.sh - Interactive Docker runner for upside2-md with Jupyter support
# Usage: ./upside.sh jupyter [--mount=<path>] [additional docker options]

set -e

# Default values
MOUNT_PATH="."
USE_SLURM="false"

# SLURM defaults (used only with singularity)
SLURM_CPUS="1"
SLURM_PARTITION="broadwl"
SLURM_MEMORY="8"
SLURM_GPUS="0"
SLURM_ACCOUNT="pi-trsosnic"
SLURM_TIME=""

# Container runtime: docker (default) or singularity
CONTAINER_RUNTIME=""
SINGULARITY_IMAGE_DIR="$(pwd)/singularity_images"
SINGULARITY_IMAGE_NAME=""
SINGULARITY_IMAGE_PATH=""

LAB_DOCKER_IMAGE="upside2-lab"
DEV_DOCKER_IMAGE="upside2-dev"
BASE_DOCKER_IMAGE="upside2-base"
LAB_DOCKERFILE_PATH=".devcontainer/Dockerfile.lab"
DEV_DOCKERFILE_PATH=".devcontainer/Dockerfile.dev"
BASE_DOCKERFILE_PATH=".devcontainer/Dockerfile"
CONTAINER_NAME="upside2-jupyter-$(date +%s)"
JUPYTER_PORT="8888"
CACHE_DIR="$(pwd)/.ccache"
OUTPUT_BASE="$(pwd)/output"

# Ensure cache directory exists
mkdir -p "$CACHE_DIR"

# Ensure output base directory exists
mkdir -p "$OUTPUT_BASE"

# Ensure singularity image directory exists
mkdir -p "$SINGULARITY_IMAGE_DIR"

# Function to show usage
show_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  build      Build Docker image with custom name/tags"
    echo "  list       List all upside-related containers and images"
    echo "  kill       Stop and remove upside containers"
    echo "  clean      Remove all upside-related Docker resources"
    echo "  run        Execute a command in the base container"
    echo "  jupyter    Launch Jupyter Lab in the background"
    echo "  develop    Launch an interactive development shell"
    echo ""
    echo "Global options:"
    echo "  --slurm              Use SLURM+Singularity (default: Docker)"
    echo ""
    echo "SLURM options (with --slurm):"
    echo "  --cpus=<n>         Number of CPUs (default: 1)"
    echo "  --partition=<name> SLURM partition (default: broadwl)"
    echo "  --memory=<GB>      Memory in GB (default: 8)"
    echo "  --gpus=<n>         Number of GPUs (default: 0, omit for CPU jobs)"
    echo "  --account=<name>   SLURM account (default: pi-trsosnic)"
    echo "  --time=<hh:mm:ss>  SLURM time limit (optional)"
    echo ""
    echo "Build options:"
    echo "  --name=<name>      Image name (default: upside2-lab)"
    echo "  --tag=<tag>        Image tag (can be used multiple times, default: latest)"
    echo "  --file=<path>      Dockerfile path (default: .devcontainer/Dockerfile)"
    echo "  --force            Force rebuild even if image exists"
    echo "  --                 Pass remaining args to docker build"
    echo ""
    echo "Kill options:"
    echo "  --name=<prefix>    Name prefix filter (default: upside)"
    echo ""
    echo "Jupyter/Develop options:"
    echo "  --mount=<path>     Mount directory to /persistent (default: current directory)"
    echo "  --port=<port>      Jupyter port (default: 8888)"
    echo "  --name=<name>      Container name (default: auto-generated)"
    echo "  --build            Force rebuild of Docker image"
    echo "  --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 build --name my-image --tag v1.0 --tag latest"
    echo "  $0 list"
    echo "  $0 kill --name upside2"
    echo "  $0 clean"
    echo "  $0 run python example/01.GettingStarted/0.run.py  # runs local file in container"
    echo "  $0 run --capture-dir=/data/results python script.py  # captures container output"
    echo "  $0 jupyter --slurm --mount=./data --port=9999"
    echo "  $0 develop --mount=. --build"
    echo ""
}
# TODO: Update help command to show expanded default values rather than hardcoded text

# Function to build lab Docker image if needed
build_lab_image() {
    if [[ "$FORCE_BUILD" == "true" ]] || ! docker image inspect "$LAB_DOCKER_IMAGE" >/dev/null 2>&1; then
        echo "Building lab Docker image: $LAB_DOCKER_IMAGE"
        docker build -f "$LAB_DOCKERFILE_PATH" -t "$LAB_DOCKER_IMAGE" .
    else
        echo "Using existing lab Docker image: $LAB_DOCKER_IMAGE"
    fi
}

# Function to build dev Docker image if needed
build_dev_image() {
    if [[ "$FORCE_BUILD" == "true" ]] || ! docker image inspect "$DEV_DOCKER_IMAGE" >/dev/null 2>&1; then
        echo "Building dev Docker image: $DEV_DOCKER_IMAGE"
        docker build -f "$DEV_DOCKERFILE_PATH" -t "$DEV_DOCKER_IMAGE" .
    else
        echo "Using existing dev Docker image: $DEV_DOCKER_IMAGE"
    fi
}

# Function to build base Docker image if needed
build_base_image() {
    if [[ "$FORCE_BUILD" == "true" ]] || ! docker image inspect "$BASE_DOCKER_IMAGE" >/dev/null 2>&1; then
        echo "Building base Docker image: $BASE_DOCKER_IMAGE"
        docker build -f "$BASE_DOCKERFILE_PATH" -t "$BASE_DOCKER_IMAGE" .
    else
        echo "Using existing base Docker image: $BASE_DOCKER_IMAGE"
    fi
}

# Function to get absolute path
get_absolute_path() {
    local path="$1"
    if [[ "$path" == "." ]]; then
        pwd
    elif [[ "$path" == /* ]]; then
        echo "$path"
    else
        echo "$(pwd)/$path"
    fi
}

# Ensure singularity image exists (pull from docker-daemon)
ensure_singularity_image() {
    local docker_image="$1"
    local sif_path="$2"
    if [[ ! -f "$sif_path" ]]; then
        echo "Singularity image not found: $sif_path"
        echo "Pulling singularity image from local docker-daemon: $docker_image"
        singularity pull "$sif_path" "docker-daemon://${docker_image}:latest"
    else
        echo "Using cached singularity image: $sif_path"
    fi
}

# Helper: Wrap a singularity command with srun and SLURM flags
wrap_with_slurm() {
    local slurm_cmd=("srun"
        "--cpus-per-task=$SLURM_CPUS"
        "--partition=$SLURM_PARTITION"
        "--mem=${SLURM_MEMORY}G"
        "--account=$SLURM_ACCOUNT"
    )
    if [[ -n "$SLURM_TIME" ]]; then
        slurm_cmd+=("--time=$SLURM_TIME")
    fi
    if [[ "$SLURM_GPUS" != "0" && -n "$SLURM_GPUS" ]]; then
        slurm_cmd+=("--gres=gpu:$SLURM_GPUS")
    fi
    # Forward all args
    slurm_cmd+=("$@")
    "${slurm_cmd[@]}"
}

# Abstraction for running containers (docker or singularity)
container_run() {
    local image="$1"
    shift
    local run_cmd=("$@")
    local mount_abs_path
    mount_abs_path=$(get_absolute_path "$MOUNT_PATH")

    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        docker run -d \
            --platform=linux/x86 \
            --name "$CONTAINER_NAME" \
            -p "$JUPYTER_PORT:8888" \
            -v "$mount_abs_path:/persistent" \
            -w /persistent \
            "$image" \
            "${run_cmd[@]}"
    elif [[ "$CONTAINER_RUNTIME" == "singularity" ]]; then
        SINGULARITY_IMAGE_NAME="${image}.sif"
        SINGULARITY_IMAGE_PATH="$SINGULARITY_IMAGE_DIR/$SINGULARITY_IMAGE_NAME"
        ensure_singularity_image "$image" "$SINGULARITY_IMAGE_PATH"
        wrap_with_slurm singularity run \
            --bind "$mount_abs_path:/persistent" \
            "$SINGULARITY_IMAGE_PATH" \
            "${run_cmd[@]}"
    else
        echo "Unknown container runtime: $CONTAINER_RUNTIME"
        exit 1
    fi
}

# Function to launch Jupyter
launch_jupyter() {
    local mount_abs_path
    mount_abs_path=$(get_absolute_path "$MOUNT_PATH")
    
    if [[ ! -d "$mount_abs_path" ]]; then
        echo "Error: Mount path '$mount_abs_path' does not exist"
        exit 1
    fi

    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        echo "Building/checking Docker image..."
        build_lab_image
    fi

    echo "Starting Jupyter Lab container..."
    echo "  - Container name: $CONTAINER_NAME"
    echo "  - Mounting: $mount_abs_path -> /persistent"
    echo "  - Jupyter port: $JUPYTER_PORT"

    # Start container with Jupyter (docker or singularity)
    container_run "$LAB_DOCKER_IMAGE" \
        bash -c "conda run -n upside2-env jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --NotebookApp.token='' --NotebookApp.password=''"

    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        # Wait a moment for Jupyter to start
        echo "Waiting for Jupyter to start..."
        sleep 3

        # Check if container is running
        if docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}" | grep -q "$CONTAINER_NAME"; then
            echo ""
            echo "✅ Jupyter Lab is running!"
            echo "🌐 Access it at: http://localhost:$JUPYTER_PORT"
            echo "📁 Working directory: /persistent (mounted from $mount_abs_path)"
            echo ""
            echo "Container management:"
            echo "  Stop:    docker stop $CONTAINER_NAME"
            echo "  Remove:  docker rm $CONTAINER_NAME"
            echo "  Logs:    docker logs $CONTAINER_NAME"
            echo "  Shell:   docker exec -it $CONTAINER_NAME bash"
        else
            echo "❌ Failed to start container. Check logs with:"
            echo "docker logs $CONTAINER_NAME"
            exit 1
        fi
    else
        echo ""
        echo "✅ Jupyter Lab (Singularity) started!"
        echo "You may need to check the output for the Jupyter URL/token."
        echo "📁 Working directory: /persistent (mounted from $mount_abs_path)"
        echo ""
        echo "Tip: Use srun or sbatch for SLURM integration if needed."
    fi
}

# Function to launch development shell
launch_dev() {
    local mount_abs_path
    mount_abs_path=$(get_absolute_path "$MOUNT_PATH")
    
    if [[ ! -d "$mount_abs_path" ]]; then
        echo "Error: Mount path '$mount_abs_path' does not exist"
        exit 1
    fi

    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        echo "Building/checking dev Docker image..."
        build_dev_image
    fi

    echo "Starting development shell..."
    echo "  - Container name: ${CONTAINER_NAME:-upside2-dev-$(date +%s)}"
    echo "  - Mounting: $mount_abs_path -> /upside2-md"
    echo "  - Cache: $CACHE_DIR -> /ccache"

    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        # Start interactive container with development tools
        docker run --rm -it \
            --platform=linux/x86 \
            --name "${CONTAINER_NAME:-upside2-dev-$(date +%s)}" \
            -v "$CACHE_DIR:/ccache" \
            -v "$mount_abs_path:/upside2-md" \
            -w /upside2-md \
            "$DEV_DOCKER_IMAGE" \
            bash
    elif [[ "$CONTAINER_RUNTIME" == "singularity" ]]; then
        SINGULARITY_IMAGE_NAME="${DEV_DOCKER_IMAGE}.sif"
        SINGULARITY_IMAGE_PATH="$SINGULARITY_IMAGE_DIR/$SINGULARITY_IMAGE_NAME"
        ensure_singularity_image "$DEV_DOCKER_IMAGE" "$SINGULARITY_IMAGE_PATH"
        wrap_with_slurm singularity exec \
            --bind "$CACHE_DIR:/ccache" \
            --bind "$mount_abs_path:/upside2-md" \
            "$SINGULARITY_IMAGE_PATH" \
            bash
    else
        echo "Unknown container runtime: $CONTAINER_RUNTIME"
        exit 1
    fi
}

# Function to run a command in base container
launch_run() {
    local args=("$@")
    local mapped_args=()
    local docker_opts=()
    local singularity_binds=()
    local pwd_abs
    pwd_abs=$(pwd)

    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        echo "Building/checking base Docker image..."
        build_base_image
    fi

    echo "Setting up volume mounts..."

    # Always mount the current directory
    docker_opts+=(-v "$pwd_abs:/persistent")
    singularity_binds+=("--bind" "$pwd_abs:/persistent")
    echo "  - Mounting: $pwd_abs -> /persistent"

    # Process capture directories
    for capture_dir in "${CAPTURE_DIRS[@]}"; do
        # Sanitize the container path to create host directory name
        local sanitized="${capture_dir#/}"        # Remove leading slash
        sanitized="${sanitized//\//_}"            # Replace / with _
        local host_dir="$OUTPUT_BASE/$sanitized"

        # Create host directory (preserving existing files)
        mkdir -p "$host_dir"

        # Add volume mount
        docker_opts+=(-v "$host_dir:$capture_dir")
        singularity_binds+=("--bind" "$host_dir:$capture_dir")
        echo "  - Capturing: $capture_dir -> $host_dir"
    done

    echo "Mapping file paths for container execution..."

    # Process each argument to map file paths
    for arg in "${args[@]}"; do
        if [[ -e "$arg" ]]; then
            # File or directory exists, get absolute path
            local abs_path
            abs_path=$(get_absolute_path "$arg")

            # Check if it's within the current working directory
            if [[ "$abs_path" == "$pwd_abs"* ]]; then
                # Map to container path
                local relative_path="${abs_path#"$pwd_abs"}"
                if [[ -z "$relative_path" ]]; then
                    # Root directory case
                    mapped_args+=("/persistent")
                else
                    mapped_args+=("/persistent$relative_path")
                fi
            else
                # File outside PWD, keep original path (may not work in container)
                echo "Warning: File '$arg' is outside current directory and may not be accessible in container"
                mapped_args+=("$arg")
            fi
        else
            # Not a file/directory, keep as-is
            mapped_args+=("$arg")
        fi
    done

    echo "Executing command in base container..."
    echo "  - Command: ${mapped_args[*]}"

    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        # Execute the command in the container
        docker run --rm \
            --platform=linux/x86 \
            "${docker_opts[@]}" \
            -w /persistent \
            "$BASE_DOCKER_IMAGE" \
            bash -c "${mapped_args[*]}"
    elif [[ "$CONTAINER_RUNTIME" == "singularity" ]]; then
        SINGULARITY_IMAGE_NAME="${BASE_DOCKER_IMAGE}.sif"
        SINGULARITY_IMAGE_PATH="$SINGULARITY_IMAGE_DIR/$SINGULARITY_IMAGE_NAME"
        ensure_singularity_image "$BASE_DOCKER_IMAGE" "$SINGULARITY_IMAGE_PATH"
        wrap_with_slurm singularity exec \
            "${singularity_binds[@]}" \
            --pwd /persistent \
            "$SINGULARITY_IMAGE_PATH" \
            bash -c "${mapped_args[*]}"
    else
        echo "Unknown container runtime: $CONTAINER_RUNTIME"
        exit 1
    fi
}

# Function to build custom image with multiple tags
build_custom_image() {
    local image_name="$1"
    local dockerfile_path="$2"
    local force_build="$3"
    shift 3
    local tags=("$@")
    
    # If no tags specified, use 'latest'
    if [[ ${#tags[@]} -eq 0 ]]; then
        tags=("latest")
    fi
    
    # Primary tag for checking if image exists
    local primary_tag="${tags[0]}"
    
    if [[ "$force_build" == "true" ]] || ! docker image inspect "$image_name:$primary_tag" >/dev/null 2>&1; then
        echo "Building Docker image: $image_name with tags: ${tags[*]}"
        echo "Using Dockerfile: $dockerfile_path"
        
        # Build with first tag
        docker build -f "$dockerfile_path" -t "$image_name:${primary_tag}" "${BUILD_EXTRA_ARGS[@]}" .
        
        # Tag with additional tags
        for tag in "${tags[@]:1}"; do
            echo "Tagging as: $image_name:$tag"
            docker tag "$image_name:$primary_tag" "$image_name:$tag"
        done
        
        echo "✅ Build complete"
    else
        echo "Image $image_name:$primary_tag already exists. Use --force to rebuild."
    fi
}

# Function to list all upside-related resources
list_upside_resources() {
    echo "=== Upside Containers ==="
    docker ps -a --filter "name=upside" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "No upside containers found"
    
    echo ""
    echo "=== Upside Images ==="
    docker images --filter "reference=*upside*" --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}" 2>/dev/null || echo "No upside images found"
    
    echo ""
    echo "=== Upside Volumes ==="
    docker volume ls --filter "name=upside" --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}" 2>/dev/null || echo "No upside volumes found"
    
    echo ""
    echo "=== Build Cache Usage ==="
    docker system df 2>/dev/null || echo "Unable to get cache info"
}

# Function to kill upside containers
kill_upside_containers() {
    local name_prefix="${1:-upside}"
    
    echo "Stopping and removing containers matching prefix: $name_prefix"
    
    # Get container IDs matching the prefix
    local container_ids
    container_ids=$(docker ps -aq --filter "name=$name_prefix" 2>/dev/null)
    
    if [[ -n "$container_ids" ]]; then
        echo "Found containers:"
        docker ps -a --filter "name=$name_prefix" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
        
        echo "Removing containers..."
        docker rm -f $container_ids
        echo "✅ Containers removed"
    else
        echo "No containers found matching prefix: $name_prefix"
    fi
}

# Function to clean all upside resources
clean_all_upside_resources() {
    echo "🧹 Cleaning all upside-related Docker resources..."
    
    # Stop and remove all upside containers
    echo "1. Removing containers..."
    local containers
    containers=$(docker ps -aq --filter "name=upside" 2>/dev/null)
    if [[ -n "$containers" ]]; then
        docker rm -f $containers
        echo "   ✅ Containers removed"
    else
        echo "   No upside containers found"
    fi
    
    # Remove upside images
    echo "2. Removing images..."
    local images
    images=$(docker images -q "*upside*" 2>/dev/null)
    if [[ -n "$images" ]]; then
        docker rmi -f $images 2>/dev/null || echo "   Some images may be in use"
        echo "   ✅ Images removed"
    else
        echo "   No upside images found"
    fi
    
    # Remove upside volumes
    echo "3. Removing volumes..."
    local volumes
    volumes=$(docker volume ls -q --filter "name=upside" 2>/dev/null)
    if [[ -n "$volumes" ]]; then
        docker volume rm $volumes 2>/dev/null || echo "   Some volumes may be in use"
        echo "   ✅ Volumes removed"
    else
        echo "   No upside volumes found"
    fi
    
    # Clean build cache
    echo "4. Cleaning build cache..."
    docker builder prune -f >/dev/null 2>&1
    echo "   ✅ Build cache cleaned"
    
    # Clean ccache directory
    if [[ -d "$CACHE_DIR" ]]; then
        echo "5. Cleaning ccache directory..."
        rm -rf "$CACHE_DIR"
        mkdir -p "$CACHE_DIR"
        echo "   ✅ ccache directory cleaned"
    fi
    
    echo "🎉 Cleanup complete!"
}

# Parse global options (e.g., --runtime)
COMMAND=""
FORCE_BUILD="false"
BUILD_IMAGE_NAME=""
BUILD_TAGS=()
BUILD_DOCKERFILE=""
BUILD_EXTRA_ARGS=()
KILL_NAME_PREFIX="upside"

# Parse global options before command
while [[ $# -gt 0 ]]; do
    case $1 in
        --slurm)
            USE_SLURM="true"
            shift
            ;;
        --runtime=*)
            # Deprecated, ignore for backward compatibility
            shift
            ;;
        --cpus=*)
            SLURM_CPUS="${1#*=}"
            shift
            ;;
        --partition=*)
            SLURM_PARTITION="${1#*=}"
            shift
            ;;
        --memory=*)
            SLURM_MEMORY="${1#*=}"
            shift
            ;;
        --gpus=*)
            SLURM_GPUS="${1#*=}"
            shift
            ;;
        --account=*)
            SLURM_ACCOUNT="${1#*=}"
            shift
            ;;
        --time=*)
            SLURM_TIME="${1#*=}"
            shift
            ;;
        build|list|kill|clean|run|jupyter|develop)
            COMMAND="$1"
            shift
            break
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

if [[ -z "$COMMAND" ]]; then
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    else
        COMMAND="$1"
        shift
    fi
fi

# Set container runtime based on --slurm
if [[ "$USE_SLURM" == "true" ]]; then
    if ! command -v singularity >/dev/null 2>&1; then
        echo "Error: --slurm requested but singularity is not available."
        exit 1
    fi
    CONTAINER_RUNTIME="singularity"
else
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_RUNTIME="docker"
    else
        echo "Error: Docker is not available and --slurm was not specified."
        exit 1
    fi
fi

echo "Using container runtime: $CONTAINER_RUNTIME"

# Parse command-specific arguments
case $COMMAND in
    build)
        # Set defaults for build
        BUILD_IMAGE_NAME=""
        BUILD_DOCKERFILE=".devcontainer/Dockerfile"
        
        while [[ $# -gt 0 ]]; do
            case $1 in
                --name=*)
                    BUILD_IMAGE_NAME="${1#*=}"
                    shift
                    ;;
                --tag=*)
                    BUILD_TAGS+=("${1#*=}")
                    shift
                    ;;
                --file=*)
                    BUILD_DOCKERFILE="${1#*=}"
                    shift
                    ;;
                --force)
                    FORCE_BUILD="true"
                    shift
                    ;;
                --help|-h)
                    echo "Usage: $0 build [options]"
                    echo "Options:"
                    echo "  --name=<name>      Image name (REQUIRED, must contain 'upside')"
                    echo "  --tag=<tag>        Image tag (can be used multiple times, default: latest)"
                    echo "  --file=<path>      Dockerfile path (default: .devcontainer/Dockerfile)"
                    echo "  --force            Force rebuild even if image exists"
                    echo "  --                 Pass remaining args to docker build"
                    exit 0
                    ;;
                --)
                    shift
                    BUILD_EXTRA_ARGS=("$@")
                    break
                    ;;
                *)
                    echo "Unknown build option: $1"
                    exit 1
                    ;;
            esac
        done
        
        # Validate required image name
        if [[ -z "$BUILD_IMAGE_NAME" ]]; then
            echo "Error: --name is required for build command"
            echo "Usage: $0 build --name=<image-name> [other options]"
            echo "Note: Image name must contain 'upside'"
            exit 1
        fi
        
        # Validate image name contains "upside"
        if [[ "$BUILD_IMAGE_NAME" != *"upside"* ]]; then
            echo "Error: Image name must contain 'upside'"
            echo "Given: $BUILD_IMAGE_NAME"
            echo "Example: --name=my-upside-image"
            exit 1
        fi
        ;;
    list)
        while [[ $# -gt 0 ]]; do
            case $1 in
                --help|-h)
                    echo "Usage: $0 list"
                    echo "Shows all upside-related containers, images, and volumes"
                    exit 0
                    ;;
                *)
                    echo "Unknown list option: $1"
                    exit 1
                    ;;
            esac
        done
        ;;
    kill)
        while [[ $# -gt 0 ]]; do
            case $1 in
                --name=*)
                    KILL_NAME_PREFIX="${1#*=}"
                    shift
                    ;;
                --help|-h)
                    echo "Usage: $0 kill [options]"
                    echo "Options:"
                    echo "  --name=<prefix>    Name prefix filter (default: upside)"
                    exit 0
                    ;;
                *)
                    echo "Unknown kill option: $1"
                    exit 1
                    ;;
            esac
        done
        ;;
    clean)
        while [[ $# -gt 0 ]]; do
            case $1 in
                --help|-h)
                    echo "Usage: $0 clean"
                    echo "Removes all upside-related containers, images, volumes, and cache"
                    exit 0
                    ;;
                *)
                    echo "Unknown clean option: $1"
                    exit 1
                    ;;
            esac
        done
        ;;
    run)
        # Initialize arrays for capture directories
        CAPTURE_DIRS=()
        RUN_ARGS=()
        
        # Parse run-specific arguments
        while [[ $# -gt 0 ]]; do
            case $1 in
                --capture-base=*)
                    OUTPUT_BASE=$(get_absolute_path "${1#*=}")
                    mkdir -p "$OUTPUT_BASE"
                    shift
                    ;;
                --capture-dir=*)
                    CAPTURE_DIRS+=("${1#*=}")
                    shift
                    ;;
                --help|-h)
                    echo "Usage: $0 run [options] <executable> [args...]"
                    echo "Options:"
                    echo "  --capture-base=<path>      Host directory for captured output (default: ./output)"
                    echo "  --capture-dir=<container>  Container directory to capture (repeatable)"
                    echo ""
                    echo "Examples:"
                    echo "  $0 run python script.py"
                    echo "  $0 run --capture-dir=/data/results python script.py"
                    echo "  $0 run --capture-base=./my_output --capture-dir=/logs python script.py"
                    exit 0
                    ;;
                *)
                    # All remaining arguments are for the executable
                    RUN_ARGS=("$@")
                    break
                    ;;
            esac
        done
        
        # Check if any arguments provided for the executable
        if [[ ${#RUN_ARGS[@]} -eq 0 ]]; then
            echo "Error: No command provided for run"
            echo "Usage: $0 run [options] <executable> [args...]"
            echo "Example: $0 run python script.py"
            exit 1
        fi
        
        break
        ;;
    jupyter|develop)
        # Parse existing jupyter/develop arguments
        while [[ $# -gt 0 ]]; do
            case $1 in
                --mount=*)
                    MOUNT_PATH="${1#*=}"
                    shift
                    ;;
                --port=*)
                    JUPYTER_PORT="${1#*=}"
                    shift
                    ;;
                --name=*)
                    CONTAINER_NAME="${1#*=}"
                    shift
                    ;;
                --build)
                    FORCE_BUILD="true"
                    shift
                    ;;
                --help|-h)
                    if [[ $COMMAND == "jupyter" ]]; then
                        echo "Usage: $0 jupyter [options]"
                        echo "Options:"
                        echo "  --mount=<path>     Mount directory to /persistent (default: current directory)"
                        echo "  --port=<port>      Jupyter port (default: 8888)"
                        echo "  --name=<name>      Container name (default: auto-generated)"
                        echo "  --build            Force rebuild of Docker image"
                    else
                        echo "Usage: $0 develop [options]"
                        echo "Options:"
                        echo "  --mount=<path>     Mount directory to /persistent (default: current directory)"
                        echo "  --name=<name>      Container name (default: auto-generated)"
                        echo "  --build            Force rebuild of Docker image"
                    fi
                    exit 0
                    ;;
                *)
                    echo "Unknown $COMMAND option: $1"
                    exit 1
                    ;;
            esac
        done
        ;;
esac

# Execute command
case $COMMAND in
    build)
        build_custom_image "$BUILD_IMAGE_NAME" "$BUILD_DOCKERFILE" "$FORCE_BUILD" "${BUILD_TAGS[@]}"
        ;;
    list)
        list_upside_resources
        ;;
    kill)
        kill_upside_containers "$KILL_NAME_PREFIX"
        ;;
    clean)
        clean_all_upside_resources
        ;;
    run)
        launch_run "${RUN_ARGS[@]}"
        ;;
    jupyter)
        launch_jupyter
        ;;
    develop)
        launch_dev
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        show_usage
        exit 1
        ;;
esac

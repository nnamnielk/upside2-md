#!/bin/bash

# upside.sh - Interactive Docker runner for upside2-md with Jupyter support
# Usage: ./upside.sh jupyter [--mount=<path>] [additional docker options]

set -e

# Jupyter Defaults
MOUNT_PATHS=(".")
DOCKER_IMAGE="upside2-lab"
DOCKERFILE_PATH=".devcontainer/Dockerfile.ipy"
CONTAINER_NAME="upside2-jupyter-$(date +%s)"
JUPYTER_PORT="8888"

# Build Defaults
BUILD_DOCKERFILE="Dockerfile"
BUILD_IMAGE_NAME="upside2-md"
BUILD_TAGS=()

# Function to show usage
show_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  jupyter    Launch Jupyter Lab in the background"
    echo "  build      Build Docker image with specified options"
    echo ""
    echo "Jupyter Options:"
    echo "  --mount=<path>     Mount directory into the container (can be used multiple times)"
    echo "                     - Format: <host_path>:<container_path>"
    echo "                     - Default: '.' is mounted to /persistent"
    echo "  --port=<port>      Jupyter port (default: 8888)"
    echo "  --name=<name>      Container name (default: auto-generated)"
    echo "  --build            Force rebuild of Docker image"
    echo ""
    echo "Build Options:"
    echo "  --dockerfile=<name> Dockerfile name in .devcontainer/ (default: Dockerfile)"
    echo "  --tag=<tag>        Add tag to built image (can be used multiple times)"
    echo "  --name=<name>      Base image name (default: upside2)"
    echo "  --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 jupyter --mount=./data"
    echo "  $0 jupyter --mount=. --port=9999"
    echo "  $0 build --dockerfile=Dockerfile.dev --tag=dev --tag=v1.0"
    echo "  $0 build --name=upside2-lab --tag=latest"
}

# Function to build Docker image if needed
build_image() {
    if [[ "$FORCE_BUILD" == "true" ]] || ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
        echo "Building Docker image: $DOCKER_IMAGE"
        docker build -f "$DOCKERFILE_PATH" -t "$DOCKER_IMAGE" .
    else
        echo "Using existing Docker image: $DOCKER_IMAGE"
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

# Function to build Docker image only
build_only() {
    local dockerfile_path=".devcontainer/$BUILD_DOCKERFILE"
    
    # Check if dockerfile exists
    if [[ ! -f "$dockerfile_path" ]]; then
        echo "Error: Dockerfile '$dockerfile_path' does not exist"
        echo "Available dockerfiles in .devcontainer/:"
        ls -1 .devcontainer/Dockerfile*
        exit 1
    fi
    
    # If no tags specified, use 'latest'
    if [[ ${#BUILD_TAGS[@]} -eq 0 ]]; then
        BUILD_TAGS=("latest")
    fi
    
    echo "Building Docker image with:"
    echo "  - Dockerfile: $dockerfile_path"
    echo "  - Base name: $BUILD_IMAGE_NAME"
    echo "  - Tags: ${BUILD_TAGS[*]}"
    
    # Build with first tag
    local first_tag="${BUILD_TAGS[0]}"
    local image_with_tag="$BUILD_IMAGE_NAME:$first_tag"
    
    echo "Building: $image_with_tag"
    docker build -f "$dockerfile_path" -t "$image_with_tag" .
    
    # Add additional tags if specified
    if [[ ${#BUILD_TAGS[@]} -gt 1 ]]; then
        for tag in "${BUILD_TAGS[@]:1}"; do
            local additional_tag="$BUILD_IMAGE_NAME:$tag"
            echo "Tagging as: $additional_tag"
            docker tag "$image_with_tag" "$additional_tag"
        done
    fi
    
    echo "✅ Build completed successfully!"
    echo "Built images:"
    for tag in "${BUILD_TAGS[@]}"; do
        echo "  - $BUILD_IMAGE_NAME:$tag"
    done
}

# Function to launch Jupyter
launch_jupyter() {
    local mount_opts=()
    local working_dir="/persistent"

    # Process mount paths
    for mount_path in "${MOUNT_PATHS[@]}"; do
        local host_path
        local container_path

        if [[ "$mount_path" == *":"* ]]; then
            host_path="${mount_path%%:*}"
            container_path="${mount_path#*:}"
        else
            host_path="$mount_path"
            container_path="/persistent"
        fi

        local abs_host_path
        abs_host_path=$(get_absolute_path "$host_path")

        if [[ ! -e "$abs_host_path" ]]; then
            echo "Error: Mount path '$abs_host_path' does not exist"
            exit 1
        fi
        mount_opts+=(-v "$abs_host_path:$container_path")
    done

    # Set working directory to the first container path if specified
    if [[ "${MOUNT_PATHS[0]}" == *":"* ]]; then
        working_dir="${MOUNT_PATHS[0]#*:}"
    fi

    echo "Building/checking Docker image..."
    build_image
    
    echo "Starting Jupyter Lab container..."
    echo "  - Container name: $CONTAINER_NAME"
    echo "  - Mounts:"
    for mount_opt in "${mount_opts[@]}"; do
        if [[ "$mount_opt" == "-v" ]]; then
            continue
        fi
        echo "    - $mount_opt"
    done
    echo "  - Jupyter port: $JUPYTER_PORT"
    
    # Start container with Jupyter
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p "$JUPYTER_PORT:8888" \
        "${mount_opts[@]}" \
        -w "$working_dir" \
        "$DOCKER_IMAGE" \
        bash -c "conda run -n upside2-env jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --notebook-dir=/ --NotebookApp.token='' --NotebookApp.password=''"
    
    # Wait a moment for Jupyter to start
    echo "Waiting for Jupyter to start..."
    sleep 3
    
    # Check if container is running
    if docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}" | grep -q "$CONTAINER_NAME"; then
        echo ""
        echo "✅ Jupyter Lab is running!"
        echo "🌐 Access it at: http://localhost:$JUPYTER_PORT"
        echo "   Working directory: $working_dir"
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
}

# Parse command line arguments
COMMAND=""
FORCE_BUILD="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        jupyter)
            COMMAND="jupyter"
            shift
            ;;
        build)
            COMMAND="build"
            shift
            ;;
        --mount=*)
            if [[ "${MOUNT_PATHS[0]}" == "." ]]; then
                MOUNT_PATHS=()
            fi
            MOUNT_PATHS+=("${1#*=}")
            shift
            ;;
        --port=*)
            JUPYTER_PORT="${1#*=}"
            shift
            ;;
        --name=*)
            if [[ "$COMMAND" == "build" ]]; then
                BUILD_IMAGE_NAME="${1#*=}"
            else
                CONTAINER_NAME="${1#*=}"
            fi
            shift
            ;;
        --dockerfile=*)
            BUILD_DOCKERFILE="${1#*=}"
            shift
            ;;
        --tag=*)
            BUILD_TAGS+=("${1#*=}")
            shift
            ;;
        --build)
            FORCE_BUILD="true"
            shift
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Validate command
if [[ -z "$COMMAND" ]]; then
    echo "Error: No command specified"
    show_usage
    exit 1
fi

# Execute command
case $COMMAND in
    jupyter)
        launch_jupyter
        ;;
    build)
        build_only
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        show_usage
        exit 1
        ;;
esac

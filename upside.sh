#!/bin/bash

# upside.sh - Interactive Docker runner for upside2-md with Jupyter support
# Usage: ./upside.sh jupyter [--mount=<path>] [additional docker options]

set -e

# Default values
MOUNT_PATH="."
DOCKER_IMAGE="upside2-lab"
DOCKERFILE_PATH=".devcontainer/Dockerfile.lab"
CONTAINER_NAME="upside2-jupyter-$(date +%s)"
JUPYTER_PORT="8888"

# Function to show usage
show_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  jupyter    Launch Jupyter Lab in the background"
    echo ""
    echo "Options:"
    echo "  --mount=<path>     Mount directory to /persistent (default: current directory)"
    echo "  --port=<port>      Jupyter port (default: 8888)"
    echo "  --name=<name>      Container name (default: auto-generated)"
    echo "  --build            Force rebuild of Docker image"
    echo "  --help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 jupyter --mount=./data"
    echo "  $0 jupyter --mount=. --port=9999"
    echo "  $0 jupyter --mount=/home/user/project --build"
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

# Function to launch Jupyter
launch_jupyter() {
    local mount_abs_path
    mount_abs_path=$(get_absolute_path "$MOUNT_PATH")
    
    if [[ ! -d "$mount_abs_path" ]]; then
        echo "Error: Mount path '$mount_abs_path' does not exist"
        exit 1
    fi
    
    echo "Building/checking Docker image..."
    build_image
    
    echo "Starting Jupyter Lab container..."
    echo "  - Container name: $CONTAINER_NAME"
    echo "  - Mounting: $mount_abs_path -> /persistent"
    echo "  - Jupyter port: $JUPYTER_PORT"
    
    # Start container with Jupyter
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p "$JUPYTER_PORT:8888" \
        -v "$mount_abs_path:/persistent" \
        -w /persistent \
        "$DOCKER_IMAGE" \
        bash -c "conda run -n upside2-env jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --NotebookApp.token='' --NotebookApp.password=''"
    
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
    *)
        echo "Error: Unknown command '$COMMAND'"
        show_usage
        exit 1
        ;;
esac

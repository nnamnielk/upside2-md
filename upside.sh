#!/bin/bash

# upside.sh - Interactive Docker runner for upside2-md with Jupyter support
# Usage: ./upside.sh jupyter [--mount=<path>] [additional docker options]

# Features to be implemented:
# - Always print docker command used
# - TBD singularity support
# - TBD cpp developer support
# - There seems to be a bug that --killall does not force a rebuild. 

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

# Manage Defaults
MANAGE_ACTION=""
MANAGE_TARGET=""

# Function to show usage
show_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  jupyter    Launch Jupyter Lab in the background"
    echo "  build      Build Docker image with specified options"
    echo "  manage     Manage upside containers and images"
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
    echo "Manage Options:"
    echo "  --list             List all upside containers"
    echo "  --list-images      List all upside images"
    echo "  --stop=<id>        Stop container with given ID"
    echo "  --kill=<id>        Stop and remove container with given ID"
    echo "  --killall          Stop and remove all upside containers"
    echo ""
    echo "Examples:"
    echo "  $0 jupyter --mount=./data"
    echo "  $0 jupyter --mount=. --port=9999"
    echo "  $0 build --dockerfile=Dockerfile.dev --tag=dev --tag=v1.0"
    echo "  $0 build --name=upside2-lab --tag=latest"
    echo "  $0 manage --list"
    echo "  $0 manage --kill=container_id"
    echo "  $0 manage --killall"
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
        --user root \
        --workdir / \
        "${mount_opts[@]}" \
        "$DOCKER_IMAGE" \
        bash -c "cd / && conda run -n upside2-env jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root --notebook-dir=/ --NotebookApp.token='' --NotebookApp.password=''"
    
    # Wait a moment for Jupyter to start
    echo "Waiting for Jupyter to start..."
    sleep 3
    
    # Check if container is running
    if docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}" | grep -q "$CONTAINER_NAME"; then
        echo ""
        echo "✅ Jupyter Lab is running!"
        echo "🌐 Access it at: http://localhost:$JUPYTER_PORT"
        echo "   Jupyter root: /"
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

# Function to manage containers
manage_containers() {
    case $MANAGE_ACTION in
        list)
            echo "Upside containers:"
            docker ps -a --filter "name=upside2-" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" || {
                echo "No upside containers found or Docker not available"
                exit 1
            }
            ;;
        list-images)
            echo "Upside images:"
            docker images --filter "reference=upside2*" --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}" || {
                echo "No upside images found or Docker not available"
                exit 1
            }
            ;;
        stop)
            if [[ -z "$MANAGE_TARGET" ]]; then
                echo "Error: Container ID required for --stop"
                exit 1
            fi
            echo "Stopping container: $MANAGE_TARGET"
            docker stop "$MANAGE_TARGET" || {
                echo "Failed to stop container $MANAGE_TARGET"
                exit 1
            }
            echo "✅ Container $MANAGE_TARGET stopped"
            ;;
        kill)
            if [[ -z "$MANAGE_TARGET" ]]; then
                echo "Error: Container ID required for --kill"
                exit 1
            fi
            echo "Stopping and removing container: $MANAGE_TARGET"
            docker stop "$MANAGE_TARGET" 2>/dev/null || true
            docker rm "$MANAGE_TARGET" || {
                echo "Failed to remove container $MANAGE_TARGET"
                exit 1
            }
            echo "✅ Container $MANAGE_TARGET stopped and removed"
            ;;
        killall)
            echo "Finding all upside containers..."
            local containers
            containers=$(docker ps -aq --filter "name=upside2-" 2>/dev/null || true)
            
            if [[ -z "$containers" ]]; then
                echo "No upside containers found"
                exit 0
            fi
            
            echo "Stopping and removing all upside containers:"
            echo "$containers" | while read -r container_id; do
                if [[ -n "$container_id" ]]; then
                    local container_name
                    container_name=$(docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null || echo "unknown")
                    # Remove leading slash from container name if present
                    container_name=${container_name#/}
                    echo "  - $container_name ($container_id)"
                    docker stop "$container_id" 2>/dev/null || true
                    docker rm "$container_id" 2>/dev/null || true
                fi
            done
            echo "✅ All upside containers stopped and removed"
            ;;
        *)
            echo "Error: No manage action specified"
            echo "Use one of: --list, --list-images, --stop=<id>, --kill=<id>, --killall"
            exit 1
            ;;
    esac
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
        manage)
            COMMAND="manage"
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
        --list)
            MANAGE_ACTION="list"
            shift
            ;;
        --list-images)
            MANAGE_ACTION="list-images"
            shift
            ;;
        --stop=*)
            MANAGE_ACTION="stop"
            MANAGE_TARGET="${1#*=}"
            shift
            ;;
        --kill=*)
            MANAGE_ACTION="kill"
            MANAGE_TARGET="${1#*=}"
            shift
            ;;
        --killall)
            MANAGE_ACTION="killall"
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
    manage)
        manage_containers
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        show_usage
        exit 1
        ;;
esac

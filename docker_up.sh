#!/bin/sh

DOCKER_IMAGE="oliverkleinmann/upside2-md:latest"

show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "This script installs Docker and the required image, and runs the container."
    echo ""
    echo "Options:"
    echo "  (no arguments)    Installs Docker (if not present) and pulls the Docker image."
    echo "  -v <path>         Launches the container and mounts the specified local directory"
    echo "                    into /upside2-md/scripts/ inside the container."
    echo "                    This option can be used multiple times to mount multiple directories."
    echo "  --help, -h        Show this help message."
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install Docker on Linux
install_docker_linux() {
    echo "Installing Docker on Linux..."
    if ! command_exists sudo; then
        echo "sudo command not found. Please run this script with a user that has sudo privileges."
        exit 1
    fi
    
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update

    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker ${USER}
    
    sudo systemctl start docker
    
    echo "Docker installed and started successfully. You may need to log out and log back in for group changes to take effect."
}

# Function to install Docker on macOS
install_docker_mac() {
    echo "Installing Docker on macOS..."
    if ! command_exists brew; then
        echo "Homebrew not found. Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    brew install --cask docker
    
    echo "Starting Docker Desktop..."
    open --background -a Docker
    
    echo "Please wait for Docker Desktop to start. This may take a few moments."
}

# Function to install Docker on Windows
install_docker_windows() {
    echo "Attempting to install Docker on Windows..."
    if ! command_exists curl; then
        echo "curl is not available. Please install curl or install Docker Desktop manually."
        exit 1
    fi

    echo "Downloading Docker Desktop for Windows..."
    curl -L "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" -o "DockerDesktopInstaller.exe"

    echo "Starting Docker Desktop installer. Please follow the on-screen instructions."
    echo "The script will continue after the installer is closed."
    start /w "" DockerDesktopInstaller.exe install --quiet

    echo "Installation process finished."
    rm DockerDesktopInstaller.exe

    echo "Starting Docker Desktop..."
    if [ -f "C:/Program Files/Docker/Docker/Docker Desktop.exe" ]; then
        start "" "C:/Program Files/Docker/Docker/Docker Desktop.exe"
    else
        echo "Could not automatically start Docker Desktop. Please start it manually."
    fi
}

# Main script execution
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    show_help
    exit 0
fi

if [ "$1" = "-v" ]; then
    VOLUME_MOUNTS=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -v)
                if [ -z "$2" ]; then
                    echo "Error: Missing volume path for -v flag." >&2
                    exit 1
                fi
                if [ ! -d "$2" ]; then
                    echo "Error: Local directory '$2' not found." >&2
                    exit 1
                fi
                
                ABS_PATH=$(cd "$2" && pwd)
                DIR_NAME=$(basename "$ABS_PATH")
                
                VOLUME_MOUNTS="$VOLUME_MOUNTS -v \"$ABS_PATH:/upside2-md/scripts/$DIR_NAME\""
                shift 2
                ;;
            *)
                echo "Error: Unknown option '$1' when specifying volumes." >&2
                exit 1
                ;;
        esac
    done

    echo "Launching Docker container with volume mounts..."
    eval "docker run -it --rm $VOLUME_MOUNTS $DOCKER_IMAGE"
else
    # Installation and setup logic
    if ! command_exists docker; then
        echo "Docker is not installed. Attempting to install..."
        OS="$(uname -s)"
        case "$OS" in
            Linux*)     install_docker_linux;;
            Darwin*)    install_docker_mac;;
            CYGWIN*|MINGW*|MSYS*) install_docker_windows;;
            *)          echo "Unsupported operating system: $OS"; exit 1;;
        esac
    else
        echo "Docker is already installed."
    fi

    # Check if the Docker image exists and ask the user if they want to re-pull
    if docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
        echo "Docker image '$DOCKER_IMAGE' is already installed."
        printf "Do you want to pull the latest version again? (y/n) "
        read -r answer
        if [ "$answer" = "y" ]; then
            echo "Pulling the latest version of $DOCKER_IMAGE..."
            docker pull "$DOCKER_IMAGE"
        else
            echo "Skipping pull. Using existing image."
        fi
    else
        echo "Pulling the Docker image: $DOCKER_IMAGE"
        docker pull "$DOCKER_IMAGE"
    fi

    echo ""
    echo "upside installed!"
    echo "You can now run the container with a volume mount using:"
    echo "$0 -v ./path/to/your/scripts"
fi

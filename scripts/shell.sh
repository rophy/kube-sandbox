#!/bin/bash
set -e

cd "$(dirname "$0")/.."

CONTAINER_NAME="kube-sandbox-dev-1"

# Check if container is already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container already running, attaching..."
    exec docker compose exec -w /workspace dev bash
fi

# Get current user's UID and GID
USER_UID=$(id -u)
USER_GID=$(id -g)

# Get docker group GID
DOCKER_GID=$(getent group docker | cut -d: -f3)

if [ -z "$DOCKER_GID" ]; then
    echo "Warning: docker group not found, docker socket access may not work"
    DOCKER_GID=999
fi

# Function to add a variable to .env only if it doesn't exist
add_env_if_missing() {
    local key="$1"
    local value="$2"

    if [ ! -f .env ]; then
        echo "${key}=${value}" > .env
        echo "Added ${key}=${value}"
    elif ! grep -q "^${key}=" .env; then
        echo "${key}=${value}" >> .env
        echo "Added ${key}=${value}"
    fi
}

# Add UID, GID, DOCKER_GID to .env if not already set
add_env_if_missing "USER_UID" "$USER_UID"
add_env_if_missing "USER_GID" "$USER_GID"
add_env_if_missing "DOCKER_GID" "$DOCKER_GID"

echo "Building container..."
docker compose build

echo "Starting container..."
docker compose up -d

echo "Entering shell..."
exec docker compose exec -w /workspace dev bash

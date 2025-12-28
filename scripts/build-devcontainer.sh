#!/bin/bash
set -e

cd "$(dirname "$0")/.."

# Get current user's UID and GID
USER_UID=$(id -u)
USER_GID=$(id -g)

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

# Add UID, GID to .env if not already set
add_env_if_missing "USER_UID" "$USER_UID"
add_env_if_missing "USER_GID" "$USER_GID"

echo "Building dev container..."
docker compose build

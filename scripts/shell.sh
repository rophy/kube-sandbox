#!/bin/bash
set -e

cd "$(dirname "$0")/.."

CONTAINER_NAME="kube-sandbox-dev-1"

# Check if container is already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container already running, attaching..."
    exec docker compose exec -w /workspace dev bash
fi

# Build the dev container
./scripts/build-devcontainer.sh

echo "Starting container..."
docker compose up -d

echo "Entering shell..."
exec docker compose exec -w /workspace dev bash

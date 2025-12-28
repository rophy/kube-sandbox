#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "Starting container..."
docker compose up -d

echo "Entering shell..."
exec docker compose exec -w /workspace dev bash

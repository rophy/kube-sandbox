#!/bin/bash
# Deploy EC2 and setup docker context for remote Docker commands
#
# Usage:
#   ./scripts/deploy-compose.sh
#
# After running, docker commands work against the remote machine:
#   docker ps
#   docker compose -f docker-compose.yaml up -d
#   docker compose -f docker-compose.yaml logs -f

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
CONTEXT_NAME="ec2-remote"

# Run terraform apply
echo "Running terraform apply..."
cd "$TERRAFORM_DIR"
terraform apply -auto-approve

# Get public IP
PUBLIC_IP=$(terraform output -raw public_ip)
REMOTE_HOST="ubuntu@$PUBLIC_IP"

echo ""
echo "Remote host: $REMOTE_HOST"

# Wait for SSH to be ready
echo "Waiting for SSH to be ready..."
for i in {1..30}; do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "$REMOTE_HOST" "echo ok" &>/dev/null; then
        echo "SSH is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "Error: SSH not ready after 30 attempts"
        exit 1
    fi
    echo "  Attempt $i/30..."
    sleep 5
done

# Wait for Docker to be ready
echo "Waiting for Docker to be ready..."
for i in {1..30}; do
    if ssh -o StrictHostKeyChecking=no "$REMOTE_HOST" "docker info" &>/dev/null; then
        echo "Docker is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "Error: Docker not ready after 30 attempts"
        exit 1
    fi
    echo "  Attempt $i/30..."
    sleep 10
done

# Create docker context and set as default
echo "Setting up docker context '$CONTEXT_NAME'..."
docker context rm "$CONTEXT_NAME" &>/dev/null || true
docker context create "$CONTEXT_NAME" --docker "host=ssh://$REMOTE_HOST"
docker context use "$CONTEXT_NAME"

echo ""
echo "=========================================="
echo "Done! Docker is now configured for remote."
echo "=========================================="
echo ""
echo "Try these commands:"
echo "  docker ps"
echo "  docker compose -f docker-compose.yaml up -d"
echo ""
echo "To switch back to local Docker:"
echo "  docker context use default"

#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
SSH_DIR="${PROJECT_DIR}/.ssh"
SSH_KEY="${SSH_DIR}/id_rsa"

echo "=== Initializing kube-sandbox ==="

# Generate SSH key if it doesn't exist
if [ ! -f "$SSH_KEY" ]; then
    echo "Generating SSH key pair..."
    mkdir -p "$SSH_DIR"
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -C "kube-sandbox"
    chmod 600 "$SSH_KEY"
    chmod 644 "${SSH_KEY}.pub"
    echo "SSH key generated at: $SSH_KEY"
else
    echo "SSH key already exists: $SSH_KEY"
fi

# Run terraform init
echo ""
echo "Running terraform init..."
cd "${PROJECT_DIR}/terraform"
terraform init

echo ""
echo "=== Initialization complete ==="

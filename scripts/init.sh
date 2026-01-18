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

# Check for backend.tfvars
BACKEND_CONFIG="${PROJECT_DIR}/terraform/backend.tfvars"

if [ ! -f "$BACKEND_CONFIG" ]; then
    echo ""
    echo "ERROR: terraform/backend.tfvars not found."
    echo ""
    echo "Please create it with your S3 bucket name:"
    echo ""
    echo "  echo 'bucket = \"your-bucket-name\"' > terraform/backend.tfvars"
    echo ""
    exit 1
fi

# Run terraform init for infra
echo ""
echo "Running terraform init for infra..."
cd "${PROJECT_DIR}/terraform/infra"
terraform init -backend-config=../backend.tfvars

# Run terraform init for cluster
echo ""
echo "Running terraform init for cluster..."
cd "${PROJECT_DIR}/terraform/cluster"
terraform init -backend-config=../backend.tfvars

echo ""
echo "=== Initialization complete ==="

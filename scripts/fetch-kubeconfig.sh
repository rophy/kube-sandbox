#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
TERRAFORM_DIR="${PROJECT_DIR}/terraform/cluster"
SSH_KEY="${PROJECT_DIR}/.ssh/id_rsa"
OUTPUT_FILE="${HOME}/.kube/config"

# Ensure ~/.kube directory exists
mkdir -p "${HOME}/.kube"

# Verify SSH key exists
if [ ! -f "$SSH_KEY" ]; then
    echo "ERROR: SSH key not found at $SSH_KEY"
    echo "Run 'make init' first to generate the SSH key."
    exit 1
fi

echo "=== Fetching kubeconfig from K3s server ==="

# Get the server IP from terraform output
cd "$TERRAFORM_DIR"
MASTER_IP=$(terraform output -raw master_public_ip 2>/dev/null || true)

# Check if we got a valid IP (not empty and not terraform warning text)
if [ -z "$MASTER_IP" ] || ! echo "$MASTER_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "ERROR: Could not get master node IP. Is the cluster deployed?"
    echo "Run 'make up' to create the cluster first."
    exit 1
fi

echo "K3s server IP: $MASTER_IP"

# Wait for nginx proxy to be ready (K3s API via nginx TLS termination)
echo "Waiting for K3s API (via nginx on port 16443) to be ready..."
API_READY=false
for i in {1..60}; do
    if curl -sk --connect-timeout 3 "https://${MASTER_IP}:16443" >/dev/null 2>&1; then
        echo "K3s API (nginx) is responding"
        API_READY=true
        break
    fi
    echo "Attempt $i/60 - waiting..."
    sleep 5
done

if [ "$API_READY" != "true" ]; then
    echo "ERROR: K3s API did not become ready in time"
    exit 1
fi

# Fetch kubeconfig via SSH into a temp file
TEMP_KUBECONFIG=$(mktemp)
echo "Fetching kubeconfig via SSH..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    ec2-user@"$MASTER_IP" "cat /tmp/kubeconfig-external.yaml" > "$TEMP_KUBECONFIG"

if [ ! -s "$TEMP_KUBECONFIG" ]; then
    echo "ERROR: Failed to fetch kubeconfig"
    rm -f "$TEMP_KUBECONFIG"
    exit 1
fi

# Fix empty server IP in kubeconfig
if grep -q "server: https://:16443" "$TEMP_KUBECONFIG"; then
    echo "Fixing server IP in kubeconfig..."
    sed -i "s|server: https://:16443|server: https://${MASTER_IP}:16443|" "$TEMP_KUBECONFIG"
fi

# Rename context/cluster/user from "default" to "kube-sandbox"
sed -i 's/: default$/: kube-sandbox/g' "$TEMP_KUBECONFIG"
sed -i 's/name: default$/name: kube-sandbox/g' "$TEMP_KUBECONFIG"

# Merge into existing ~/.kube/config without clobbering other contexts
if [ -f "$OUTPUT_FILE" ]; then
    MERGED=$(mktemp)
    KUBECONFIG="${TEMP_KUBECONFIG}:${OUTPUT_FILE}" kubectl config view --flatten > "$MERGED"
    chmod 600 "$MERGED"
    mv "$MERGED" "$OUTPUT_FILE"
else
    chmod 600 "$TEMP_KUBECONFIG"
    mv "$TEMP_KUBECONFIG" "$OUTPUT_FILE"
fi
rm -f "$TEMP_KUBECONFIG"

# Set kube-sandbox as the current context
kubectl config use-context kube-sandbox

SERVER_URL=$(kubectl config view -o jsonpath='{.clusters[?(@.name=="kube-sandbox")].cluster.server}')
echo ""
echo "Kubeconfig merged into: $OUTPUT_FILE"
echo "Server URL: $SERVER_URL"
echo "Context: kube-sandbox (active)"
echo ""
echo "kubectl is now ready to use:"
echo "  kubectl get nodes"

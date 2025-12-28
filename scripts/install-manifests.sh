#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"

echo "=== Installing additional manifests ==="

# Wait for nodes to be ready
echo "Waiting for nodes to be ready..."
for i in {1..30}; do
    READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
    if [ "$READY_NODES" -ge 1 ]; then
        echo "Found $READY_NODES ready node(s)"
        break
    fi
    echo "Attempt $i/30 - waiting for nodes..."
    sleep 10
done

# Wait for EBS CSI driver to be ready (it's deployed by K3s via server manifests)
echo "Waiting for EBS CSI driver to be ready..."
for i in {1..30}; do
    CSI_READY=$(kubectl get pods -n kube-system -l app=ebs-csi-controller --no-headers 2>/dev/null | grep -c "Running" || true)
    if [ "$CSI_READY" -ge 1 ]; then
        echo "EBS CSI controller is running"
        break
    fi
    echo "Attempt $i/30 - waiting for EBS CSI driver..."
    sleep 10
done

# Install registry
echo "Installing Docker registry..."
kubectl apply -f "${MANIFESTS_DIR}/registry.yaml"

# Wait for registry to be ready
echo "Waiting for registry to be ready..."
kubectl -n registry rollout status deployment/registry --timeout=300s

# Get registry endpoint (public IP from Terraform)
cd "${SCRIPT_DIR}/../terraform"
DB_IP=$(terraform output -raw db_node_public_ip 2>/dev/null)

if [ -z "$DB_IP" ]; then
    echo "WARNING: Could not get DB node public IP from Terraform"
    exit 1
fi

# Add to /etc/hosts if not already present
REGISTRY_HOST="registry.registry.svc.cluster.local"
if grep -q "$REGISTRY_HOST" /etc/hosts 2>/dev/null; then
    # Update existing entry
    sudo sed -i "s/.*${REGISTRY_HOST}.*/${DB_IP} ${REGISTRY_HOST}/" /etc/hosts
    echo "Updated /etc/hosts: ${DB_IP} ${REGISTRY_HOST}"
else
    # Add new entry
    echo "${DB_IP} ${REGISTRY_HOST}" | sudo tee -a /etc/hosts >/dev/null
    echo "Added to /etc/hosts: ${DB_IP} ${REGISTRY_HOST}"
fi

echo ""
echo "=== Registry installed successfully ==="
echo ""
echo "Registry endpoint: ${REGISTRY_HOST}:30500"
echo ""
echo "Push and use images as:"
echo "  docker tag myimage:latest ${REGISTRY_HOST}:30500/myimage:latest"
echo "  docker push ${REGISTRY_HOST}:30500/myimage:latest"
echo ""

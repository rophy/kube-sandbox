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

# Get registry endpoint
DB_IP=$(kubectl get nodes -l workload=db -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || \
        kubectl get nodes -l workload=db -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo ""
echo "=== Registry installed successfully ==="
echo ""
echo "Registry endpoint: registry.registry.svc.cluster.local:30500"
echo ""
echo "To use the same image name everywhere, add this to /etc/hosts:"
echo "  ${DB_IP} registry.registry.svc.cluster.local"
echo ""
echo "Then push and use images as:"
echo "  docker tag myimage:latest registry.registry.svc.cluster.local:30500/myimage:latest"
echo "  docker push registry.registry.svc.cluster.local:30500/myimage:latest"
echo ""

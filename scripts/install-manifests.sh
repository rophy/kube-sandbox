#!/bin/bash
set -e

echo "=== Waiting for cluster to be ready ==="

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

echo ""
echo "=== Cluster ready ==="
echo ""
echo "Container registry: \$SKAFFOLD_DEFAULT_REPO (ECR)"
echo ""

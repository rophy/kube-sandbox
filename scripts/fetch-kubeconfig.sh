#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
OUTPUT_FILE="${SCRIPT_DIR}/../kubeconfig.yaml"

echo "=== Fetching kubeconfig from K3s server ==="

# Get the server IP from terraform output
cd "$TERRAFORM_DIR"
DB_IP=$(terraform output -raw db_node_public_ip 2>/dev/null)

if [ -z "$DB_IP" ]; then
    echo "ERROR: Could not get DB node IP. Is the infrastructure deployed?"
    exit 1
fi

echo "K3s server IP: $DB_IP"

# Wait for K3s to be ready
echo "Waiting for K3s API to be ready..."
for i in {1..60}; do
    if curl -sk "https://${DB_IP}:6443" >/dev/null 2>&1; then
        echo "K3s API is responding"
        break
    fi
    echo "Attempt $i/60 - waiting..."
    sleep 10
done

# Try to fetch kubeconfig via SSH or SSM
if [ -n "$SSH_KEY" ]; then
    echo "Fetching kubeconfig via SSH..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        ec2-user@"$DB_IP" "cat /tmp/kubeconfig-external.yaml" > "$OUTPUT_FILE"
else
    echo "No SSH_KEY set. Trying via SSM..."
    INSTANCE_ID=$(terraform output -json ssm_session_commands | jq -r '.db' | grep -oP 'i-[a-z0-9]+')

    if [ -n "$INSTANCE_ID" ]; then
        # Use SSM to get kubeconfig
        aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["cat /tmp/kubeconfig-external.yaml"]' \
            --output text \
            --query 'Command.CommandId' > /tmp/ssm_cmd_id

        CMD_ID=$(cat /tmp/ssm_cmd_id)
        sleep 5

        aws ssm get-command-invocation \
            --instance-id "$INSTANCE_ID" \
            --command-id "$CMD_ID" \
            --query 'StandardOutputContent' \
            --output text > "$OUTPUT_FILE"
    else
        echo "ERROR: Cannot determine how to fetch kubeconfig."
        echo "Manual method: ssh ec2-user@${DB_IP} 'cat /tmp/kubeconfig-external.yaml' > kubeconfig.yaml"
        exit 1
    fi
fi

if [ -s "$OUTPUT_FILE" ]; then
    # Fix file permissions to avoid kubectl warnings
    chmod 600 "$OUTPUT_FILE"

    # Fix empty server IP in kubeconfig
    if grep -q "server: https://:6443" "$OUTPUT_FILE"; then
        echo "Fixing server IP in kubeconfig..."
        sed -i "s|server: https://:6443|server: https://${DB_IP}:6443|" "$OUTPUT_FILE"
    fi

    # Extract and install K3s CA certificate
    echo "Extracting K3s CA certificate..."
    CA_CERT_FILE="/usr/local/share/ca-certificates/k3s-ca.crt"

    # Extract certificate-authority-data from kubeconfig and decode
    CA_DATA=$(grep "certificate-authority-data:" "$OUTPUT_FILE" | awk '{print $2}')
    if [ -n "$CA_DATA" ]; then
        echo "$CA_DATA" | base64 -d > "$CA_CERT_FILE" 2>/dev/null || \
        echo "$CA_DATA" | base64 --decode > "$CA_CERT_FILE"

        # Update system CA certificates
        if command -v update-ca-certificates &> /dev/null; then
            update-ca-certificates 2>/dev/null && echo "CA certificate installed to system trust store"
        elif command -v update-ca-trust &> /dev/null; then
            cp "$CA_CERT_FILE" /etc/pki/ca-trust/source/anchors/
            update-ca-trust extract && echo "CA certificate installed to system trust store"
        else
            echo "Warning: Could not update system CA certificates automatically"
            echo "CA cert saved to: $CA_CERT_FILE"
        fi
    else
        echo "Warning: Could not extract CA certificate from kubeconfig"
    fi

    # Verify kubeconfig has correct server URL
    SERVER_URL=$(grep "server:" "$OUTPUT_FILE" | awk '{print $2}')
    echo ""
    echo "Kubeconfig saved to: $OUTPUT_FILE"
    echo "Server URL: $SERVER_URL"
    echo ""
    echo "To use:"
    echo "  export KUBECONFIG=$OUTPUT_FILE"
    echo "  kubectl get nodes"
else
    echo "ERROR: Failed to fetch kubeconfig"
    exit 1
fi

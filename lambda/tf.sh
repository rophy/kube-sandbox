#!/bin/bash
# Terraform Lambda handler for apply/destroy operations
# Uses AWS Lambda's provided.al2023 runtime with custom bootstrap

set -euo pipefail

handler() {
    local action="${TF_ACTION:-}"
    local repo_url="${GITHUB_REPO_URL:-}"
    local state_bucket="${TF_STATE_BUCKET:-}"
    local workdir="/tmp/workspace"

    # Validate
    if [[ "$action" != "apply" && "$action" != "destroy" ]]; then
        echo '{"status":"error","error":"TF_ACTION must be apply or destroy"}'
        return
    fi

    if [[ -z "$repo_url" || -z "$state_bucket" ]]; then
        echo '{"status":"error","error":"GITHUB_REPO_URL and TF_STATE_BUCKET required"}'
        return
    fi

    echo "Starting cluster $action..." >&2

    # Clean up and clone
    rm -rf "$workdir"
    echo "Cloning $repo_url..." >&2
    if ! git clone --depth=1 "$repo_url" "$workdir" >&2 2>&1; then
        echo '{"status":"error","error":"Git clone failed"}'
        return
    fi

    cd "$workdir/terraform/cluster"

    # Create backend config
    echo "bucket = \"$state_bucket\"" > backend.tfvars

    # Create SSH key (real for apply, dummy for destroy)
    mkdir -p "$workdir/.ssh"
    if [[ "$action" == "apply" ]]; then
        echo "Generating SSH key..." >&2
        ssh-keygen -t rsa -b 4096 -f "$workdir/.ssh/id_rsa" -N "" -C "kube-sandbox" >&2 2>&1
    else
        echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC dummy-key" > "$workdir/.ssh/id_rsa.pub"
    fi

    # Terraform init
    echo "Running terraform init..." >&2
    if ! terraform init -backend-config=backend.tfvars -plugin-dir=/opt/terraform-providers -no-color >&2 2>&1; then
        echo '{"status":"error","error":"Terraform init failed"}'
        return
    fi

    # Force unlock any stale locks before destroy
    if [[ "$action" == "destroy" ]]; then
        echo "Checking for stale state locks..." >&2
        lock_id=$(terraform plan -no-color 2>&1 | grep -oP 'ID:\s+\K[a-f0-9-]+' | head -1) || true
        if [[ -n "$lock_id" ]]; then
            echo "Found stale lock $lock_id, force unlocking..." >&2
            terraform force-unlock -force "$lock_id" >&2 2>&1 || true
        fi
    fi

    # Terraform action
    echo "Running terraform $action..." >&2
    if terraform "$action" -auto-approve -no-color >&2 2>&1; then
        echo "{\"status\":\"${action}ed\",\"output\":\"Terraform $action completed successfully\"}"
    else
        echo "{\"status\":\"${action}_failed\",\"error\":\"Terraform $action failed\"}"
    fi
}

# Lambda runtime API loop
RUNTIME_API="${AWS_LAMBDA_RUNTIME_API}"

while true; do
    # Get next event
    HEADERS=$(mktemp)
    EVENT=$(curl -sS -LD "$HEADERS" "http://${RUNTIME_API}/2018-06-01/runtime/invocation/next")
    REQUEST_ID=$(grep -i Lambda-Runtime-Aws-Request-Id "$HEADERS" | tr -d '[:space:]' | cut -d: -f2)
    rm -f "$HEADERS"

    # Run handler (stderr goes to CloudWatch, only stdout is the response)
    RESPONSE=$(handler) || true

    # Send response
    curl -sS -X POST "http://${RUNTIME_API}/2018-06-01/runtime/invocation/${REQUEST_ID}/response" \
        -d "$RESPONSE"
done

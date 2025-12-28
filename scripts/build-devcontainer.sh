#!/bin/bash
set -e

cd "$(dirname "$0")/.."

# Get current user's UID and GID
USER_UID=$(id -u)
USER_GID=$(id -g)

# Function to add a variable to .env only if it doesn't exist
add_env_if_missing() {
    local key="$1"
    local value="$2"

    if [ ! -f .env ]; then
        echo "${key}=${value}" > .env
        echo "Added ${key}=${value}"
    elif ! grep -q "^${key}=" .env; then
        echo "${key}=${value}" >> .env
        echo "Added ${key}=${value}"
    fi
}

# Add UID, GID to .env if not already set
add_env_if_missing "USER_UID" "$USER_UID"
add_env_if_missing "USER_GID" "$USER_GID"

# Get AWS account ID and region for ECR registry
echo "Checking AWS credentials..."
if ! AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
    echo "ERROR: AWS credentials not configured or invalid"
    echo "Please configure AWS credentials before building the dev container"
    exit 1
fi

AWS_REGION=$(aws configure get region 2>/dev/null || echo "")
if [ -z "$AWS_REGION" ]; then
    echo "ERROR: AWS region not configured"
    echo "Please run: aws configure set region <your-region>"
    exit 1
fi

SKAFFOLD_DEFAULT_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
add_env_if_missing "SKAFFOLD_DEFAULT_REPO" "$SKAFFOLD_DEFAULT_REPO"

echo "Building dev container..."
docker compose build

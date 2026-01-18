.PHONY: help shell up down init kubeconfig build-devcontainer build infra-up infra-down

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

shell: ## Start container and open shell
	./scripts/shell.sh

build-devcontainer: ## Build the dev container image
	./scripts/build-devcontainer.sh

build: ## Build Lambda image (kube-sandbox-tf)
	docker build -f Dockerfile.tf -t kube-sandbox-tf:latest .

# ===== INFRA (Lambda, IAM - zero cost, deploy once) =====

infra-up: ## Deploy infra (Lambda, IAM)
	cd terraform/infra && terraform apply -auto-approve

infra-down: ## Destroy infra (Lambda, IAM)
	cd terraform/infra && terraform destroy -auto-approve

# ===== CLUSTER (VPC, EC2, K3s - costs money) =====

up: ## Create K3s cluster and fetch kubeconfig
	cd terraform/cluster && timeout 180 terraform apply -auto-approve
	timeout 300 ./scripts/fetch-kubeconfig.sh
	./scripts/install-manifests.sh
	@echo ""
	@echo "=== Cluster ready ==="

down: ## Destroy K3s cluster and clean up
	cd terraform/cluster && terraform destroy -auto-approve
	@echo "Checking for orphaned EBS volumes..."
	@aws ec2 describe-volumes \
		--filters "Name=tag:kube-sandbox,Values=true" "Name=status,Values=available" \
		--query 'Volumes[*].VolumeId' --output json 2>/dev/null | \
		jq -r '.[]' | xargs -r -I{} aws ec2 delete-volume --volume-id {} 2>/dev/null || true
	@echo "Cleanup complete"

# ===== UTILITIES =====

init: ## Initialize project (terraform init + generate SSH key)
	./scripts/init.sh

kubeconfig: ## Fetch kubeconfig from K3s cluster
	./scripts/fetch-kubeconfig.sh

.PHONY: help shell up down init kubeconfig

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

shell: ## Start container and open shell
	docker compose up -d
	docker compose exec -w /workspace dev bash

up: ## Create K3s cluster and fetch kubeconfig
	cd terraform && timeout 180 terraform apply -auto-approve
	timeout 60 ./scripts/fetch-kubeconfig.sh

down: ## Destroy K3s cluster and clean up
	cd terraform && terraform destroy -auto-approve
	@echo "Checking for orphaned EBS volumes..."
	@aws ec2 describe-volumes \
		--filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
		--query 'Volumes[*].VolumeId' --output text 2>/dev/null | \
		xargs -r -n1 aws ec2 delete-volume --volume-id 2>/dev/null || true
	@echo "Cleanup complete"

init: ## Run terraform init
	cd terraform && terraform init

kubeconfig: ## Fetch kubeconfig from K3s cluster
	./scripts/fetch-kubeconfig.sh

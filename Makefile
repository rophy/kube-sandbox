.PHONY: help shell up down clean clean-ebs build init apply destroy kubeconfig

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

shell: up ## Start container and open shell
	docker compose exec -w /workspace/terraform dev bash

up: ## Start dev container
	docker compose up -d

down: ## Stop dev container
	docker compose down

clean: down ## Stop container, remove volumes, and clean orphaned EBS
	docker compose down -v
	@echo "Checking for orphaned EBS volumes..."
	@aws ec2 describe-volumes \
		--filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
		--query 'Volumes[*].VolumeId' --output text 2>/dev/null | \
		xargs -r -n1 aws ec2 delete-volume --volume-id 2>/dev/null || true
	@echo "Cleanup complete"

clean-ebs: ## Delete orphaned EBS volumes created by K8s CSI driver
	@echo "Finding orphaned EBS volumes..."
	@aws ec2 describe-volumes \
		--filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
		--query 'Volumes[*].[VolumeId,Size,State,Tags[?Key==`kubernetes.io/created-for/pvc/name`].Value|[0]]' \
		--output table
	@echo ""
	@read -p "Delete all listed volumes? [y/N] " confirm && \
		[ "$$confirm" = "y" ] && \
		aws ec2 describe-volumes \
			--filters "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
			--query 'Volumes[*].VolumeId' --output text | \
			xargs -r -n1 aws ec2 delete-volume --volume-id || \
		echo "Aborted"

build: ## Rebuild dev container
	docker compose up -d --build

init: up ## Run terraform init
	docker compose exec -w /workspace/terraform dev terraform init

apply: up ## Run terraform apply
	docker compose exec -w /workspace/terraform dev terraform apply

destroy: up ## Run terraform destroy
	docker compose exec -w /workspace/terraform dev terraform destroy

kubeconfig: up ## Fetch kubeconfig from K3s cluster
	docker compose exec dev /workspace/scripts/fetch-kubeconfig.sh

.PHONY: help shell up down

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

shell: ## Start dev container and open shell
	docker compose up -d
	docker compose exec dev bash

up: ## Deploy EC2 infrastructure and setup docker context
	./scripts/deploy-compose.sh

down: ## Destroy EC2 infrastructure
	cd terraform && terraform destroy -auto-approve

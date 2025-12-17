.PHONY: help shell up down clean build init apply destroy

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

shell: up ## Start container and open shell
	docker compose exec dev bash

up: ## Start dev container
	docker compose up -d

down: ## Stop dev container
	docker compose down

clean: ## Stop container and remove volumes
	docker compose down -v

build: ## Rebuild dev container
	docker compose up -d --build

init: up ## Run terraform init
	docker compose exec dev bash -c "cd terraform && terraform init"

apply: up ## Run terraform apply
	docker compose exec dev bash -c "cd terraform && terraform apply"

destroy: up ## Run terraform destroy
	docker compose exec dev bash -c "cd terraform && terraform destroy"

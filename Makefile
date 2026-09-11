# Solrise ERP - single entry point for every environment.
# Every target sources .env, so the same commands work on CachyOS + any VPS.
SHELL := /bin/bash
ENV_FILE := .env
LOCAL := compose/compose.local.yaml
PROD := compose/compose.prod.yaml

COMPOSE_CMD ?= podman-compose

-include $(ENV_FILE)
export

.PHONY: help image local-up local-down init site logs ps shell \
        prod-up prod-down prod-logs backup restore fixtures pull-fixtures

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

image: ## Build the custom erpnext+hrms image
	./scripts/build-image.sh

local-up: ## Start the local stack (detached)
	$(COMPOSE_CMD) -f $(LOCAL) --env-file $(ENV_FILE) up -d

local-down: ## Stop the local stack (keeps volumes)
	$(COMPOSE_CMD) -f $(LOCAL) --env-file $(ENV_FILE) down

site: ## Create the site and install apps (idempotent)
	./scripts/create-site.sh

init: image local-up site ## Full local bring-up in one shot

logs: ## Tail all local container logs
	$(COMPOSE_CMD) -f $(LOCAL) --env-file $(ENV_FILE) logs -f --tail=100

ps: ## Show local container status
	$(COMPOSE_CMD) -f $(LOCAL) --env-file $(ENV_FILE) ps

shell: ## Open a bash shell in the backend container
	$(CONTAINER_ENGINE) exec -it solrise-backend bash

prod-up: ## Start the production stack
	$(COMPOSE_CMD) -f $(PROD) --env-file $(ENV_FILE) up -d

prod-down: ## Stop the production stack
	$(COMPOSE_CMD) -f $(PROD) --env-file $(ENV_FILE) down

prod-logs: ## Tail production logs
	$(COMPOSE_CMD) -f $(PROD) --env-file $(ENV_FILE) logs -f --tail=100

backup: ## Dump DB + files and copy them to $(BACKUP_DIR)
	./scripts/backup.sh

restore: ## Restore from $(BACKUP_DIR) (see scripts/restore.sh usage)
	./scripts/restore.sh

fixtures: ## Export fixtures inside the container and pull them into ./fixtures
	./scripts/export-fixtures.sh
	./scripts/pull-fixtures.sh

pull-fixtures: ## Pull already-exported fixtures out of the container
	./scripts/pull-fixtures.sh

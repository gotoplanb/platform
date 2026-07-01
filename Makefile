# Watch platform — deterministic create / teardown / verify of the AWS estate.
# Thin wrappers over scripts/{create,teardown,sweep}.sh (which own DAG order, the kept
# foundation, the :bootstrap seed, and parallelism). Non-interactive by default. Applies use
# the write profile (watch-bootstrap); the sweep is read-only (watch-ro). See scripts/README.md.

SHELL := /bin/bash
export AWS_REGION ?= us-east-1

export ENV ?= prod

.PHONY: help create create-staging create-prod pipeline up \
        teardown teardown-staging teardown-prod down \
        sweep recreate migrate seed deploy-frontend live

help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n",$$1,$$2}'

## --- create (write: watch-bootstrap) ---
create: ## (Re)create both envs + pipeline, DAG-parallel (idempotent)
	scripts/create.sh both -y
create-staging: ## Create staging only
	scripts/create.sh staging -y
create-prod: ## Create prod only
	scripts/create.sh prod -y
pipeline: ## Re-apply just the pipeline (repoint at current staging/prod ARNs, #28)
	scripts/create.sh pipeline -y
up: create ## Alias: create

## --- teardown (write: watch-bootstrap) ---
teardown: ## Destroy both envs + pipeline in parallel (keeps foundation)
	scripts/teardown.sh both --parallel -y
teardown-staging: ## Destroy staging only (leaves prod + pipeline up)
	scripts/teardown.sh staging -y
teardown-prod: ## Destroy prod only
	scripts/teardown.sh prod -y
down: teardown ## Alias: teardown

## --- database (write: watch-bootstrap) — fresh envs come up empty until migrated ---
migrate: ## Run migrations on ENV (default prod): make migrate ENV=prod
	scripts/db.sh migrate $(ENV)
seed: ## Seed demo data (t1a..t3b + incidents) on ENV: make seed ENV=prod
	scripts/db.sh seed $(ENV)
deploy-frontend: ## Sync status-page SPA to S3 + invalidate CloudFront on ENV
	scripts/deploy-frontend.sh $(ENV)

## --- verify (read-only: watch-ro) ---
sweep: ## Billable-orphan check; nonzero exit if anything lingers
	AWS_PROFILE=watch-ro scripts/sweep.sh

## --- full cycle ---
recreate: teardown create ## Teardown then create (fresh both envs)
live: create migrate seed deploy-frontend ## Create + migrate + seed + deploy status page (prod)

# Watch platform — deterministic create / teardown / verify of the AWS estate.
# Thin wrappers over scripts/{create,teardown,sweep}.sh (which own DAG order, the kept
# foundation, the :bootstrap seed, and parallelism). Non-interactive by default. Applies use
# the write profile (watch-bootstrap); the sweep is read-only (watch-ro). See scripts/README.md.

SHELL := /bin/bash
export AWS_REGION ?= us-east-1

export ENV ?= prod

.PHONY: help create create-staging create-prod pipeline up \
        teardown teardown-staging teardown-prod down \
        sweep doctor nuke tofu-pin recreate migrate seed deploy-frontend deploy live live-finish lambda-promote live-verify

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
deploy: ## Promote latest main off :bootstrap: run the pipeline, wait to the prod-approval gate
	scripts/deploy.sh

## --- verify (read-only: watch-ro) ---
sweep: ## Billable-orphan check; nonzero exit if anything lingers
	AWS_PROFILE=watch-ro scripts/sweep.sh
doctor: ## Cross-account state-vs-reality drift: orphans (billable) + ghosts; nonzero on orphans (#44)
	scripts/doctor.sh $(if $(SCOPE),$(SCOPE),both)

## --- force-clean (write: watch-bootstrap) — LAST RESORT when teardown leaves orphans ---
nuke: ## Force-delete ALL billable watch-* in an account, keeping the persist-list (#45): make nuke TARGET=nonprod
	scripts/nuke.sh $(if $(TARGET),$(TARGET),both)
tofu-pin: ## Install the repo-pinned OpenTofu into .bin/tofu (.opentofu-version)
	scripts/tofu-pin.sh

## --- full cycle ---
recreate: teardown create ## Teardown then create (fresh both envs)
live: ## ONE approval: stand up the platform + BOTH app envs (create, migrate+seed+status page for each, promote latest main)
	scripts/create.sh both -y
	scripts/db.sh migrate staging
	scripts/db.sh migrate prod
	scripts/db.sh seed staging
	scripts/db.sh seed prod
	scripts/deploy-frontend.sh staging
	scripts/deploy-frontend.sh prod
	scripts/deploy.sh

live-finish: ## Finish a create aborted by the AWS holds: migrate -> promote Lambdas -> seed -> app DNS (idempotent)
	scripts/live-finish.sh both
lambda-promote: ## Package + promote the escalation/intake Lambdas from ../watch to ENVS (default staging): make lambda-promote LAMBDA_ENVS=staging
	scripts/lambda-promote.sh $(if $(LAMBDA_ENVS),$(LAMBDA_ENVS),staging)
live-verify: ## Read-only smoke: app+worker services running and the API healthy per env
	scripts/live-verify.sh both

variable "name" {
  description = "Pipeline/name prefix (e.g. watch)."
  type        = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# ---- Source (GitHub via CodeConnections) ------------------------------------

variable "connection_arn" {
  description = "CodeConnections ARN for the GitHub source, from the persistent connection stack (#33)."
  type        = string
}

variable "github_repo_id" {
  type    = string
  default = "gotoplanb/watch"
}

variable "github_branch" {
  type    = string
  default = "main"
}

variable "staging_url" {
  description = "Public HTTPS URL of the staging app for the DAST scan (#32) + smoke test."
  type        = string
  default     = "https://watch-stg.davestanton.com"
}

variable "staging_status_url" {
  description = "Public HTTPS URL of the staging status page for the smoke test (#… E2E gate)."
  type        = string
  default     = "https://status-stg.davestanton.com"
}

variable "staging_intake_secret_param" {
  description = "SSM parameter name of the staging intake webhook secret (injected into the smoke test)."
  type        = string
  default     = "/watch/staging/intake-webhook-secret"
}

variable "staging_checks_secret_param" {
  description = "SSM parameter name of the staging checks webhook secret (the session-check dogfood in the smoke posts to /api/checks/webhook, which validates this — distinct from the intake secret)."
  type        = string
  default     = "/watch/staging/checks-webhook-secret"
}

# ---- Shared build artifact (platform#20) ------------------------------------

variable "ecr_repository_url" {
  description = "Shared ECR repo. Built once; the same digest is promoted to every env."
  type        = string
}

variable "container_name" {
  type    = string
  default = "app"
}

variable "container_port" {
  type    = number
  default = 8000
}

# ---- Per-env deploy targets (promote staging -> prod) -----------------------
# Ordered: the pipeline deploys to `staging` first, then (after manual approval) `prod`,
# using the SAME image digest. Each env brings its own ECS service, blue/green wiring,
# roles, DB-migration placement, and rollback alarms.

variable "staging" {
  type = object({
    cluster_name            = string
    service_name            = string
    task_family             = string
    production_listener_arn = string
    test_listener_arn       = string
    blue_target_group_name  = string
    green_target_group_name = string
    execution_role_arn      = string
    task_role_arn           = string
    private_subnet_ids      = list(string)
    app_sg_id               = string
    rollback_alarm_names    = list(string)
    # The async worker (ADR-025) runs the SAME image as the app, a different command — and until
    # platform#61 nothing promoted it, so it sat on the `bootstrap` placeholder forever. Empty when
    # the env has no worker; the deploy action is then simply not created.
    worker_service_name = optional(string, "")
    # The worker's own task role (ADR-025). Distinct from the app's, so it needs its own PassRole.
    worker_task_role_arn = optional(string, "")
  })
}

variable "prod" {
  type = object({
    cluster_name            = string
    service_name            = string
    task_family             = string
    production_listener_arn = string
    test_listener_arn       = string
    blue_target_group_name  = string
    green_target_group_name = string
    execution_role_arn      = string
    task_role_arn           = string
    private_subnet_ids      = list(string)
    app_sg_id               = string
    rollback_alarm_names    = list(string)
    # The async worker (ADR-025) runs the SAME image as the app, a different command — and until
    # platform#61 nothing promoted it, so it sat on the `bootstrap` placeholder forever. Empty when
    # the env has no worker; the deploy action is then simply not created.
    worker_service_name = optional(string, "")
    # The worker's own task role (ADR-025). Distinct from the app's, so it needs its own PassRole.
    worker_task_role_arn = optional(string, "")
  })
}

variable "deploy_config_name" {
  type    = string
  default = "CodeDeployDefault.ECSLinear10PercentEvery1Minutes"
}

variable "prod_deploy_role_arn" {
  description = "Cross-account deploy role in watch-prod that the DeployProd action assumes (ADR-020). Empty = single-account (prod deploy stays in this account's CodeDeploy — legacy)."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "permissions_boundary" {
  description = "Permissions boundary applied to every role this module creates (ADR-044). Empty = none, for estates that have not adopted the fence."
  type        = string
  default     = ""
}

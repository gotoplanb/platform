variable "name" {
  description = "Pipeline/name prefix (e.g. watch)."
  type        = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# ---- Source (GitHub via CodeConnections) ------------------------------------

variable "github_repo_id" {
  type    = string
  default = "gotoplanb/watch"
}

variable "github_branch" {
  type    = string
  default = "main"
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
  })
}

variable "deploy_config_name" {
  type    = string
  default = "CodeDeployDefault.ECSLinear10PercentEvery1Minutes"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}

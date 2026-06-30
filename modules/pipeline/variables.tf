variable "name" {
  description = "Name prefix, e.g. watch-prod."
  type        = string
}

variable "env" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# ---- Source (GitHub via CodeConnections) ------------------------------------

variable "github_repo_id" {
  description = "owner/repo of the app source (the watch repo)."
  type        = string
  default     = "gotoplanb/watch"
}

variable "github_branch" {
  type    = string
  default = "main"
}

# ---- Build target (app stack #6 outputs) ------------------------------------

variable "ecr_repository_url" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "ecs_task_family" {
  type = string
}

variable "container_name" {
  type    = string
  default = "app"
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "execution_role_arn" {
  description = "App execution role — CodeBuild needs PassRole to register task defs."
  type        = string
}

variable "task_role_arn" {
  description = "App task role — CodeBuild needs PassRole to register task defs."
  type        = string
}

# ---- Migration hook placement (network #3) ----------------------------------
# The BeforeAllowTraffic hook runs `migrate` as a Fargate task in the app's subnets/SG.

variable "private_subnet_ids" {
  type = list(string)
}

variable "app_sg_id" {
  type = string
}

# ---- Blue/green wiring (app stack #6) ---------------------------------------

variable "production_listener_arn" {
  type = string
}

variable "test_listener_arn" {
  type = string
}

variable "blue_target_group_name" {
  type = string
}

variable "green_target_group_name" {
  type = string
}

# ---- Deploy safety ----------------------------------------------------------

variable "rollback_alarm_names" {
  description = "CloudWatch alarm names that trigger auto-rollback during a deploy (e.g. the escalation alarm #7)."
  type        = list(string)
  default     = []
}

variable "deploy_config_name" {
  description = "CodeDeploy ECS config: canary/linear traffic shift."
  type        = string
  default     = "CodeDeployDefault.ECSLinear10PercentEvery1Minutes"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}

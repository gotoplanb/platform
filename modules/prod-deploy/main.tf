# Prod deploy plane for watch-prod (ADR-020): the prod ECS blue/green CodeDeploy + the
# cross-account role the nonprod pipeline assumes to drive it. A Terragrunt stack has a single
# terraform source, so this thin module composes modules/codedeploy + modules/xacct-deploy-role.
# The CodeDeploy app/DG and the role names are predictable (watch-prod / watch-prod-deploy) so the
# pipeline references them by name/ARN without a reverse dependency.

variable "name" {
  type    = string
  default = "watch-prod"
}
variable "trusted_account_id" {
  description = "The nonprod pipeline account allowed to assume the deploy role."
  type        = string
}
variable "artifact_bucket_arn" {
  type = string
}
variable "artifact_kms_key_arn" {
  type = string
}
variable "cluster_name" {
  type = string
}
variable "service_name" {
  type = string
}
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
variable "execution_role_arn" {
  type = string
}
variable "task_role_arn" {
  type = string
}
variable "rollback_alarm_names" {
  type    = list(string)
  default = []
}
variable "tags" {
  type    = map(string)
  default = {}
}

module "codedeploy" {
  source                  = "../codedeploy"
  name                    = var.name
  cluster_name            = var.cluster_name
  service_name            = var.service_name
  production_listener_arn = var.production_listener_arn
  test_listener_arn       = var.test_listener_arn
  blue_target_group_name  = var.blue_target_group_name
  green_target_group_name = var.green_target_group_name
  rollback_alarm_names    = var.rollback_alarm_names
  tags                    = var.tags
}

module "deploy_role" {
  source               = "../xacct-deploy-role"
  name                 = "${var.name}-deploy" # watch-prod-deploy (predictable ARN for the pipeline)
  trusted_account_id   = var.trusted_account_id
  artifact_bucket_arn  = var.artifact_bucket_arn
  artifact_kms_key_arn = var.artifact_kms_key_arn
  pass_role_arns       = [var.execution_role_arn, var.task_role_arn]
  tags                 = var.tags
}

output "codedeploy_app_name" {
  value = module.codedeploy.app_name
}
output "deploy_role_arn" {
  value = module.deploy_role.role_arn
}

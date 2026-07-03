variable "name" {
  description = "Full CodeDeploy app + deployment-group name (e.g. watch-prod)."
  type        = string
}

variable "deploy_config_name" {
  type    = string
  default = "CodeDeployDefault.ECSLinear10PercentEvery1Minutes"
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
variable "rollback_alarm_names" {
  type    = list(string)
  default = []
}
variable "tags" {
  type    = map(string)
  default = {}
}

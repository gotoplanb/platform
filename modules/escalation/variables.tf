variable "name" {
  description = "Name prefix, e.g. watch-prod. Also the state machine name (the app predicts this ARN)."
  type        = string
}

variable "env" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# ---- Lambda VPC placement (network #3) + data plane (data #4) ----------------
# The decision Lambdas django.setup() and call incidents.services against RDS, so they
# run in the VPC (private subnets) with the app SG (already allowed app->data). VPC
# Lambdas have no public IP, so reaching Secrets Manager requires NAT (ha) — escalation
# targets the ha profile; lean/staging needs NAT or interface endpoints.

variable "private_subnet_ids" {
  type = list(string)
}

variable "app_sg_id" {
  type = string
}

variable "db_address" {
  type = string
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "db_master_secret_arn" {
  type = string
}

variable "db_kms_key_arn" {
  type = string
}

variable "django_secret_key_param_arn" {
  description = "SSM ARN of the Django secret (settings import needs it); the Lambda fetches at runtime."
  type        = string
}

variable "lambda_memory" {
  type    = number
  default = 512
}

variable "lambda_timeout" {
  description = "Must comfortably exceed a commit's DB work; well under the tier SLAs."
  type        = number
  default     = 30
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

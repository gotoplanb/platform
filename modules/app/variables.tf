variable "name" {
  description = "Name prefix, e.g. watch-prod."
  type        = string
}

variable "env" {
  description = "Environment (staging|prod)."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

# ---- Placement (network stack #3) -------------------------------------------

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "app_sg_id" {
  type = string
}

variable "private_networking" {
  description = "ha: tasks in private subnets, no public IP (egress via NAT). lean: public subnets + public IP."
  type        = bool
  default     = false
}

# ---- Data plane (data stack #4) ---------------------------------------------

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
  description = "Secrets Manager ARN of the RDS master secret (JSON {username,password})."
  type        = string
}

variable "db_kms_key_arn" {
  description = "CMK protecting the DB master secret (data stack), for kms:Decrypt."
  type        = string
}

variable "valkey_url" {
  type = string
}

# ---- Config plane (secrets+appconfig stack #5) ------------------------------

variable "django_secret_key_param_arn" {
  type = string
}

variable "intake_webhook_secret_param_arn" {
  type = string
}

variable "appconfig_application_name" {
  type = string
}

variable "appconfig_environment_name" {
  type = string
}

variable "appconfig_profile_name" {
  type = string
}

variable "appconfig_read_policy_arn" {
  description = "IAM policy (from #5) the AppConfig Agent task role needs."
  type        = string
}

variable "secrets_read_policy_arn" {
  description = "IAM policy (from #5) the execution role needs for SSM secrets."
  type        = string
}

# ---- Service shape ----------------------------------------------------------

variable "image_uri" {
  description = "Full image URI. Empty => the ECR repo's :bootstrap tag (replaced by the pipeline #10)."
  type        = string
  default     = ""
}

variable "task_cpu" {
  type    = number
  default = 256
}

variable "task_memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  description = "Service task count. Set 0 until an image exists in ECR (#10)."
  type        = number
  default     = 2
}

variable "autoscale_min" {
  type    = number
  default = 2
}

variable "autoscale_max" {
  type    = number
  default = 6
}

variable "autoscale_cpu_target" {
  type    = number
  default = 60
}

variable "otel_exporter_endpoint" {
  description = "OTLP/HTTP endpoint (Watchtower collector). Empty disables export until #11 wires it."
  type        = string
  default     = ""
}

variable "appconfig_agent_image" {
  type    = string
  default = "public.ecr.aws/aws-appconfig/aws-appconfig-agent:2.x"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}

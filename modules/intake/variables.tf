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

# ---- Consumer placement (network #3) + data plane (data #4) ------------------
# The consumer is an SQS-triggered Django Lambda (create_incident_idempotent ->
# start_escalation); VPC-attached for RDS. The INGEST path (API GW -> SQS) has no Lambda,
# so capture stays up even when the app/consumer tier is impaired (ADR-002).

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
  description = "SSM ARN of the Django secret (consumer settings import)."
  type        = string
}

# ---- Webhook auth (config #5) -----------------------------------------------

variable "webhook_secret_param_name" {
  description = "SSM parameter NAME of the shared webhook secret (authorizer reads it)."
  type        = string
}

variable "webhook_secret_param_arn" {
  description = "SSM parameter ARN of the shared webhook secret (authorizer IAM)."
  type        = string
}

variable "max_receive_count" {
  description = "Deliveries before a message goes to the DLQ."
  type        = number
  default     = 5
}

variable "lambda_timeout" {
  type    = number
  default = 30
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}

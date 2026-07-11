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

variable "bedrock_model_id" {
  type        = string
  description = "Bedrock model/inference-profile id for the AI-drafted RCA (ADR-033). Sonnet by default; access must be granted per account."
  default     = "us.anthropic.claude-sonnet-4-20250514-v1:0"
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

variable "image_repository_url" {
  description = "Shared ECR repository URL (platform#20). The task def's image lives here."
  type        = string
}

variable "image_uri" {
  description = "Full image URI. Empty => the shared repo's :bootstrap tag (replaced by the pipeline)."
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

# Telemetry (ADR-016 / #18): the app is backend-agnostic — it exports OTLP to a LOCAL Alloy
# sidecar, never a remote/vendor endpoint. Where telemetry actually goes is the sidecar's
# forward target (the per-env gateway, #19/#29), not an app env var.
variable "alloy_image" {
  description = "Grafana Alloy sidecar image (OTLP collector). Pin for prod."
  type        = string
  default     = "grafana/alloy:latest"
}

variable "telemetry_gateway_endpoint" {
  description = "Where the Alloy sidecar forwards OTLP (the per-env gateway, #19). Empty = debug-sink (receives + logs), so the app→sidecar plumbing is verifiable before the gateway exists."
  type        = string
  default     = ""
}

variable "service_version" {
  description = "service.version resource attribute (git SHA / image tag); the pipeline can override per build."
  type        = string
  default     = "bootstrap"
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

variable "app_hostname" {
  description = "If set, add an HTTPS :443 listener using the ACM cert for this domain (#13)."
  type        = string
  default     = ""
}

variable "certificate_arn" {
  description = "ACM cert ARN for the :443 listener. If set, used directly (from a cert stack, #34); otherwise the cert is looked up by app_hostname. Prod leaves this empty (cert kept + found by lookup)."
  type        = string
  default     = ""
}

variable "hsts_seconds" {
  description = "Strict-Transport-Security max-age emitted by Django when app_hostname is set (#30). 31536000 = 1 year."
  type        = number
  default     = 31536000
}

# ---- Async worker + job queue (ADR-025) -------------------------------------
# Gated: enable_worker=false (default) leaves prod untouched — no queue, no worker, and the
# cloud-mode env vars below only take effect where explicitly set.

variable "enable_worker" {
  description = "Stand up the SQS job queue (+DLQ) and the run_sqs_worker ECS service (ADR-025)."
  type        = bool
  default     = false
}

variable "worker_desired_count" {
  description = "Worker service task count. 1 is plenty for the status-page/check/webhook volume."
  type        = number
  default     = 1
}

# Cloud-mode toggles (ADR-022/023/025). Default matches the app's own defaults (local/synchronous);
# set false to enqueue to SQS for the worker to drain.
variable "checks_local_mode" {
  description = "true = run Session Checks synchronously in-request; false = enqueue for the worker."
  type        = bool
  default     = true
}

variable "webhooks_local_mode" {
  description = "true = POST webhooks synchronously in-request; false = enqueue for the worker."
  type        = bool
  default     = true
}

variable "trace_store_provider" {
  description = "Session Check trace backend: none | tempo."
  type        = string
  default     = "none"
}

variable "tempo_query_url" {
  description = "Tempo query-frontend base URL (when trace_store_provider=tempo)."
  type        = string
  default     = ""
}

# New SSM SecureString ARNs (config stack). Empty => the secret is omitted from the task def.
variable "session_user_hmac_key_param_arn" {
  type    = string
  default = ""
}

variable "checks_webhook_secret_param_arn" {
  type    = string
  default = ""
}

variable "webhook_echo_secret_param_arn" {
  type    = string
  default = ""
}

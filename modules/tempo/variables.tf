variable "name" {
  description = "Env-scoped name prefix, e.g. watch-staging."
  type        = string
}

variable "region" {
  type = string
}

variable "namespace" {
  description = "Cloud Map private DNS namespace for the obs slice, e.g. watch-obs.svc."
  type        = string
  default     = "watch-obs.svc"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type    = list(string)
  default = []
}

variable "public_subnet_ids" {
  type    = list(string)
  default = []
}

variable "private_networking" {
  description = "true → private subnets + NAT; false (lean) → public subnets + public IP. Mirrors the env."
  type        = bool
  default     = true
}

variable "gateway_sg_id" {
  description = "The telemetry gateway's SG — allowed to reach Tempo on the OTLP ports."
  type        = string
}

variable "app_sg_id" {
  description = "App/worker SG — allowed to reach the Tempo query API (:3200) for Session Check (ADR-022). Empty = no query ingress."
  type        = string
  default     = ""
}

variable "tempo_image" {
  type    = string
  default = "grafana/tempo:2.6.1"
}

variable "trace_retention" {
  description = "Compactor block retention (warm-minimal staging default)."
  type        = string
  default     = "48h"
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "cpu" {
  type    = number
  default = 512
}

variable "memory" {
  type    = number
  default = 1024
}

variable "log_retention_days" {
  type    = number
  default = 7
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

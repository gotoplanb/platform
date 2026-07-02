variable "name" {
  description = "Env-scoped name prefix, e.g. watch-staging."
  type        = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type    = list(string)
  default = []
}

variable "private_networking" {
  description = "true (ha) → private subnets + NAT; false (lean) → public subnets + public IP. Mirrors the app."
  type        = bool
  default     = true
}

variable "app_sg_id" {
  description = "The app tasks' security group — allowed to reach the gateway on the OTLP ports."
  type        = string
}

variable "alloy_image" {
  type    = string
  default = "grafana/alloy:v1.5.1"
}

variable "forward_endpoint" {
  description = "In-VPC gRPC endpoint the gateway exports to (the Watchtower Tempo slice). Empty => debug sink. Ignored when vendor_endpoint is set."
  type        = string
  default     = ""
}

# Managed-vendor export (ADR-016 §2: prod → Grafana Cloud / Datadog / Sumo). When set, the
# gateway exports via OTLP/HTTP + basic auth over TLS. The token is delivered through the
# task-def secrets block (SSM/Secrets ARN), never inlined.
variable "vendor_endpoint" {
  description = "HTTPS OTLP endpoint of the managed vendor. Takes precedence over forward_endpoint."
  type        = string
  default     = ""
}
variable "vendor_auth_header" {
  description = "Full Authorization header value for the vendor OTLP export (e.g. \"Basic <base64>\"), i.e. the header half of Grafana Cloud's OTEL_EXPORTER_OTLP_HEADERS. Sensitive (the base64 encodes the token); Terraform stores it as an SSM SecureString and the gateway reads it via the secrets block. Empty => no vendor export."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tail_sampling" {
  description = "#23: keep all errors + slow traces, sample a % of the rest. Needs whole traces — gateway only."
  type        = bool
  default     = false
}

variable "sampling_percentage" {
  type    = number
  default = 10
}

variable "desired_count" {
  description = "Warm-minimal scaling: 0 idle, 1+ when telemetry is being exercised."
  type        = number
  default     = 1
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}

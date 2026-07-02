# Shared Grafana Alloy config renderer (platform#19, ADR-016). One config, two roles, so staging
# and prod share the shape and only the last hop differs:
#   role = "sidecar"  — one per app task: receive the app's OTLP on localhost, batch, forward to
#                       the per-env gateway.
#   role = "gateway"  — one per env: receive from the sidecars, (optionally) tail-sample traces
#                       (#23), batch, export to the destination (Watchtower slice / vendor).
# `forward_endpoint` empty => a debug sink, so the pipeline is valid + verifiable before a real
# destination exists (the destination is NOT a prerequisite). The debug sink + tail_sampling are
# experimental Alloy components — run the collector with --stability.level=experimental.

variable "role" {
  type = string
  validation {
    condition     = contains(["sidecar", "gateway"], var.role)
    error_message = "role must be \"sidecar\" or \"gateway\"."
  }
}

variable "grpc_port" {
  type    = number
  default = 4317
}
variable "http_port" {
  type    = number
  default = 4318
}

variable "forward_endpoint" {
  description = "gRPC endpoint this collector exports to (the gateway, for a sidecar; the backend, for a gateway). Empty => debug sink."
  type        = string
  default     = ""
}

variable "tail_sampling" {
  description = "Gateway only (#23): keep all errors + slow traces, sample a % of the rest."
  type        = bool
  default     = false
}
variable "sampling_percentage" {
  type    = number
  default = 10
}

# Vendor export (ADR-016 §2: prod → managed vendor, e.g. Grafana Cloud). When set, the gateway
# exports via OTLP/HTTP with basic auth over TLS instead of the plaintext in-VPC gRPC hop. The
# token is NOT here — Alloy reads it from an env var (fed by the task-def secrets block), so it
# never lands in config/state.
variable "vendor_endpoint" {
  description = "HTTPS OTLP endpoint of a managed vendor (e.g. https://otlp-gateway-<region>.grafana.net/otlp). Takes precedence over forward_endpoint."
  type        = string
  default     = ""
}
variable "vendor_auth_username" {
  description = "Basic-auth username for the vendor (Grafana Cloud instance ID)."
  type        = string
  default     = ""
}
variable "vendor_token_env" {
  description = "Name of the env var holding the vendor token (Alloy reads it via sys.env)."
  type        = string
  default     = "VENDOR_OTLP_TOKEN"
}

locals {
  has_vendor  = var.vendor_endpoint != ""
  has_grpc    = !local.has_vendor && var.forward_endpoint != ""
  do_sampling = var.role == "gateway" && var.tail_sampling

  # Basic-auth extension for the vendor export (Grafana Cloud). Password comes from an env var,
  # never the config text.
  auth_block = local.has_vendor ? "otelcol.auth.basic \"vendor\" {\n  username = \"${var.vendor_auth_username}\"\n  password = sys.env(\"${var.vendor_token_env}\")\n}\n" : ""

  # Destination, in precedence order: managed vendor (OTLP/HTTP + basic auth + TLS) →
  # in-VPC gRPC (plaintext, SG-scoped) → debug sink (no backend wired yet).
  exporter_block = (
    local.has_vendor ? "otelcol.exporter.otlphttp \"dest\" {\n  client {\n    endpoint = \"${var.vendor_endpoint}\"\n    auth     = otelcol.auth.basic.vendor.handler\n  }\n}" :
    local.has_grpc ? "otelcol.exporter.otlp \"dest\" {\n  client {\n    endpoint = \"${var.forward_endpoint}\"\n    tls { insecure = true }\n  }\n}" :
    "otelcol.exporter.debug \"dest\" {\n  verbosity = \"basic\"\n}"
  )
  dest_input = (
    local.has_vendor ? "otelcol.exporter.otlphttp.dest.input" :
    local.has_grpc ? "otelcol.exporter.otlp.dest.input" :
    "otelcol.exporter.debug.dest.input"
  )

  # Traces enter tail-sampling (gateway + enabled) or go straight to batch.
  traces_entry = local.do_sampling ? "otelcol.processor.tail_sampling.ts.input" : "otelcol.processor.batch.b.input"

  tail_sampling_raw = <<-EOT
    otelcol.processor.tail_sampling "ts" {
      decision_wait = "10s"
      policy { name = "errors" type = "status_code"   status_code { status_codes = ["ERROR"] } }
      policy { name = "slow"   type = "latency"       latency { threshold_ms = 1000 } }
      policy { name = "sample" type = "probabilistic" probabilistic { sampling_percentage = ${var.sampling_percentage} } }
      output { traces = [otelcol.processor.batch.b.input] }
    }
  EOT
  tail_sampling_block = local.do_sampling ? local.tail_sampling_raw : ""

  config = <<-EOT
    otelcol.receiver.otlp "in" {
      grpc { endpoint = "0.0.0.0:${var.grpc_port}" }
      http { endpoint = "0.0.0.0:${var.http_port}" }
      output {
        traces  = [${local.traces_entry}]
        metrics = [otelcol.processor.batch.b.input]
        logs    = [otelcol.processor.batch.b.input]
      }
    }
    ${local.tail_sampling_block}
    otelcol.processor.batch "b" {
      output {
        traces  = [${local.dest_input}]
        metrics = [${local.dest_input}]
        logs    = [${local.dest_input}]
      }
    }
    ${local.auth_block}${local.exporter_block}
  EOT
}

output "config" {
  description = "The rendered Alloy River config."
  value       = local.config
}

output "needs_experimental" {
  description = "True when the config uses an experimental component (debug sink / tail_sampling) — pass --stability.level=experimental."
  value       = (!local.has_vendor && !local.has_grpc) || local.do_sampling
}

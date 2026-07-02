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

locals {
  has_dest   = var.forward_endpoint != ""
  do_sampling = var.role == "gateway" && var.tail_sampling

  # Destination: real OTLP export, or a debug sink until a backend is wired.
  exporter_block = local.has_dest ? (
    "otelcol.exporter.otlp \"dest\" {\n  client {\n    endpoint = \"${var.forward_endpoint}\"\n    tls { insecure = true }\n  }\n}"
    ) : (
    "otelcol.exporter.debug \"dest\" {\n  verbosity = \"basic\"\n}"
  )
  dest_input = local.has_dest ? "otelcol.exporter.otlp.dest.input" : "otelcol.exporter.debug.dest.input"

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
    ${local.exporter_block}
  EOT
}

output "config" {
  description = "The rendered Alloy River config."
  value       = local.config
}

output "needs_experimental" {
  description = "True when the config uses an experimental component (debug sink / tail_sampling) — pass --stability.level=experimental."
  value       = !local.has_dest || local.do_sampling
}

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
  description = "Gateway tail-sampling: the % of boring reads kept (errors/slow/writes are always kept)."
  type        = number
  default     = 10
}
variable "slow_threshold_ms" {
  description = "Gateway tail-sampling: traces slower than this are always kept."
  type        = number
  default     = 1000
}
variable "keep_authenticated_attribute" {
  description = "Gateway tail-sampling: span attribute whose presence means an authenticated / session-bearing trace — kept 100% (never sampled) so Session Check (ADR-022) is reliable and sessions are reconstructable. Empty = disabled. Sampling then only touches unauthenticated noise."
  type        = string
  default     = "session.id"
}
variable "dest_traces_only" {
  description = "True when the destination only accepts traces (e.g. Tempo) — metrics + logs are dropped at the receiver instead of being exported and rejected. False for a full LGTM/vendor (Grafana Cloud)."
  type        = bool
  default     = false
}

# Vendor export (ADR-016 §2: prod → managed vendor, e.g. Grafana Cloud). When set, the gateway
# exports via OTLP/HTTP with basic auth over TLS instead of the plaintext in-VPC gRPC hop. The
# token is NOT here — Alloy reads it from an env var (fed by the task-def secrets block), so it
# never lands in config/state.
variable "vendor_endpoint" {
  description = "HTTPS OTLP endpoint of a managed vendor (Grafana Cloud's OTEL_EXPORTER_OTLP_ENDPOINT, e.g. https://otlp-gateway-<zone>.grafana.net/otlp). Takes precedence over forward_endpoint."
  type        = string
  default     = ""
}
variable "vendor_auth_header_env" {
  description = "Name of the env var holding the full Authorization header value (e.g. \"Basic <base64>\") — Alloy reads it via sys.env. This is the header half of Grafana Cloud's OTEL_EXPORTER_OTLP_HEADERS."
  type        = string
  default     = "VENDOR_OTLP_AUTH"
}

locals {
  has_vendor  = var.vendor_endpoint != ""
  has_grpc    = !local.has_vendor && var.forward_endpoint != ""
  do_sampling = var.role == "gateway" && var.tail_sampling

  # Destination, in precedence order: managed vendor (OTLP/HTTP over TLS, Authorization header
  # from an env var — the shape Grafana Cloud emits) → in-VPC gRPC (plaintext, SG-scoped) →
  # debug sink (no backend wired yet). The header value (which encodes the token) is never in
  # the config text — Alloy reads it via sys.env.
  exporter_block = (
    local.has_vendor ? "otelcol.exporter.otlphttp \"dest\" {\n  client {\n    endpoint = \"${var.vendor_endpoint}\"\n    headers  = {\n      \"Authorization\" = sys.env(\"${var.vendor_auth_header_env}\"),\n    }\n  }\n}" :
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

  # Metrics + logs: forwarded to the destination, unless it's traces-only (Tempo) — then dropped
  # at the receiver so they aren't exported and rejected with "Unimplemented".
  non_trace_out = var.dest_traces_only ? "[]" : "[otelcol.processor.batch.b.input]"

  # Incident-tuned tail-sampling (ADR-016 §3 / #23). A trace is KEPT if it matches ANY policy —
  # so keep everything that matters on an incident tool, and sample only the boring reads:
  #   errors  — every failed request (a T1 never loses an error trace)
  #   slow    — every request over the latency floor (the ones you investigate)
  #   writes  — every state transition: ack / escalate / resolve / intake are all non-GET, and
  #             writes are rare + high-value, so they're never sampled away
  #   reads   — a probabilistic slice of the rest (health checks, status page, list/detail GETs)
  # http.method is the app's semconv (confirmed in Tempo); add http.request.method if it upgrades.
  # Authenticated / session-bearing traces (any span carrying keep_authenticated_attribute, e.g.
  # session.id) are kept 100% — never sampled — so a Session Check (ADR-022) can always find AND
  # reconstruct a session, even when it was all successful GETs. Only unauthenticated noise (health
  # checks, /api/status, webhooks) falls through to the probabilistic `reads` policy below.
  auth_policy_str     = <<-POL
        policy {
          name = "authenticated"
          type = "string_attribute"
          string_attribute {
            key                    = "${var.keep_authenticated_attribute}"
            values                 = [".+"]
            enabled_regex_matching = true
          }
        }
  POL
  keep_auth_policy    = var.keep_authenticated_attribute != "" ? local.auth_policy_str : ""
  tail_sampling_raw   = <<-EOT
    otelcol.processor.tail_sampling "ts" {
      decision_wait = "10s"
      ${local.keep_auth_policy}
      policy {
        name = "errors"
        type = "status_code"
        status_code {
          status_codes = ["ERROR"]
        }
      }
      policy {
        name = "slow"
        type = "latency"
        latency {
          threshold_ms = ${var.slow_threshold_ms}
        }
      }
      policy {
        name = "writes"
        type = "string_attribute"
        string_attribute {
          key    = "http.method"
          values = ["POST", "PUT", "PATCH", "DELETE"]
        }
      }
      policy {
        name = "reads"
        type = "probabilistic"
        probabilistic {
          sampling_percentage = ${var.sampling_percentage}
        }
      }
      output {
        traces = [otelcol.processor.batch.b.input]
      }
    }
  EOT
  tail_sampling_block = local.do_sampling ? local.tail_sampling_raw : ""

  config = <<-EOT
    otelcol.receiver.otlp "in" {
      grpc { endpoint = "0.0.0.0:${var.grpc_port}" }
      http { endpoint = "0.0.0.0:${var.http_port}" }
      output {
        traces  = [${local.traces_entry}]
        metrics = ${local.non_trace_out}
        logs    = ${local.non_trace_out}
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
  value       = (!local.has_vendor && !local.has_grpc) || local.do_sampling
}

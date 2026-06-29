variable "name" {
  description = "Name prefix, e.g. watch-prod."
  type        = string
}

variable "env" {
  description = "Environment name (staging|prod); used in param paths and the AppConfig environment."
  type        = string
}

variable "region" {
  description = "AWS region (for IAM resource ARNs)."
  type        = string
  default     = "us-east-1"
}

variable "flags" {
  description = <<-EOT
    Flag/rollout-mode document mirrored to the AppConfig hosted config (ADR-003/014).
    Booleans for on/off release flags (read by flags.is_enabled); strings for rollout
    modes "on|off|sample:R" (read by rollout.active). Per-environment values.
  EOT
  type        = any
  default = {
    new_triage_ui            = false
    auto_route_on_escalation = true
    devops_agent             = "off" # operational toggle (ADR-014): off in personal, "on" for work
  }
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}

variable "name" {
  description = "Name prefix, e.g. watch-prod."
  type        = string
}

variable "env" {
  type = string
}

variable "alb_arn" {
  description = "App ALB ARN (#6) — for the 5xx alarm dimension."
  type        = string
}

variable "alb_5xx_threshold" {
  description = "ELB/target 5xx count over the period that trips the alarm (deploy gate)."
  type        = number
  default     = 5
}

variable "masked_data_identifiers" {
  description = "Managed data identifiers masked at the log sink (floor; app-layer redaction stays authoritative)."
  type        = list(string)
  default = [
    "arn:aws:dataprotection::aws:data-identifier/EmailAddress",
    "arn:aws:dataprotection::aws:data-identifier/IpAddress",
  ]
}

variable "tags" {
  type    = map(string)
  default = {}
}

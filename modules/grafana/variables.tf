variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type    = list(string)
  default = []
}

variable "private_networking" {
  type    = bool
  default = true
}

variable "cluster_arn" {
  description = "The shared obs ECS cluster (from modules/tempo)."
  type        = string
}

variable "tempo_query_endpoint" {
  description = "Tempo HTTP query API, e.g. http://tempo.watch-obs.svc:3200."
  type        = string
}

variable "tempo_sg_id" {
  description = "Tempo's SG — a rule is added allowing Grafana to reach its query API."
  type        = string
}

variable "tempo_api_port" {
  type    = number
  default = 3200
}

variable "grafana_image" {
  type    = string
  default = "grafana/grafana:11.3.1"
}

variable "desired_count" {
  type    = number
  default = 1
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

variable "permissions_boundary" {
  description = "Permissions boundary applied to every role this module creates (ADR-044). Empty = none, for estates that have not adopted the fence."
  type        = string
  default     = ""
}

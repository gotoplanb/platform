variable "name" {
  description = "Name prefix, e.g. watch-prod."
  type        = string
}

# ---- Placement (from the network stack) -------------------------------------

variable "private_subnet_ids" {
  description = "Private subnet ids for the DB + cache subnet groups."
  type        = list(string)
}

variable "data_sg_id" {
  description = "Security group allowing app->data on 5432/6379 (network stack output)."
  type        = string
}

# ---- RDS Postgres -----------------------------------------------------------

variable "postgres_version" {
  description = "Postgres major version."
  type        = string
  default     = "16"
}

variable "postgres_family" {
  description = "Parameter group family; must match postgres_version major."
  type        = string
  default     = "postgres16"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_name" {
  description = "Initial database name (matches app POSTGRES_DB)."
  type        = string
  default     = "watch"
}

variable "master_username" {
  description = "Master username (matches app POSTGRES_USER)."
  type        = string
  default     = "watch"
}

variable "allocated_storage" {
  description = "Initial storage (GiB)."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling (GiB)."
  type        = number
  default     = 100
}

variable "multi_az" {
  description = "Multi-AZ RDS (ha, ADR-005) vs single-AZ (lean)."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Block deletes. OFF during the create/destroy test loop; real prod flips on."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. true for ephemeral; real prod flips off."
  type        = bool
  default     = true
}

# ---- ElastiCache Valkey -----------------------------------------------------

variable "valkey_version" {
  description = "ElastiCache Valkey engine version."
  type        = string
  default     = "8.0"
}

variable "valkey_node_type" {
  description = "Valkey node type."
  type        = string
  default     = "cache.t4g.micro"
}

variable "valkey_transit_encryption" {
  description = "TLS in transit (requires app rediss://). Off by default to keep redis:// working."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}

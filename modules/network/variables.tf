variable "name" {
  description = "Name prefix for network resources, e.g. watch-prod."
  type        = string
}

variable "region" {
  description = "AWS region (for the S3 gateway endpoint service name)."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to spread public+private subnets across."
  type        = number
  default     = 2
}

variable "enable_nat" {
  description = "Create NAT gateway(s) so private subnets have egress (ha profile). Lean = false."
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "One shared NAT (cheaper) vs one per AZ (HA). Only used when enable_nat=true."
  type        = bool
  default     = true
}

variable "app_port" {
  description = "Container port the ALB forwards to."
  type        = number
  default     = 8000
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}

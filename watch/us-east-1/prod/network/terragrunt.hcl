# Network stack for watch / prod / us-east-1 (platform#3). VPC + public/private subnets,
# IGW, NAT (per env toggle), S3 endpoint, tiered SGs. Consumed by the data (#4) and app
# (#6) stacks via dependency outputs.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${get_repo_root()}//modules/network"
}

inputs = {
  name       = "${local.env.project}-${local.env.env}"
  region     = local.env.region
  enable_nat = local.env.enable_nat
  tags       = { env = local.env.env }
}

# Network stack for watch / staging / us-east-1 (platform#3). Lean profile (no NAT):
# ephemeral env, spun up for a pipeline run then destroyed (ADR-015).

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

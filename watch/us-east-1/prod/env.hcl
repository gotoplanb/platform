# Env-level inputs for watch / prod / us-east-1. Stack terragrunt.hcl files read this via
#   read_terragrunt_config(find_in_parent_folders("env.hcl"))
# Cost profile = lean by default (ADR-015); flip the toggles for the `ha` profile.
locals {
  project   = "watch"
  env       = "prod"
  region    = "us-east-1"
  ephemeral = false # prod is persistent

  cost_profile       = "lean"
  private_networking = false # lean: public subnets, no NAT
  enable_nat         = false
  multi_az           = false # lean: single-AZ RDS (set true for ADR-005 survival)
}

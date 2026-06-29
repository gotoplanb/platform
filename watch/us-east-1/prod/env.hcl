# Env-level inputs for watch / prod / us-east-1. Stack terragrunt.hcl files read this via
#   read_terragrunt_config(find_in_parent_folders("env.hcl"))
# Cost profile (ADR-015). Prod defaults to `ha` — the architecturally sound design (app
# in private subnets, NAT egress, AZ-redundant) rather than the cheapest layout, since
# this is the persistent env. Staging stays `lean` for fast create/destroy cycles. Flip
# enable_nat=false here for a quick cheap prod cycle.
locals {
  project   = "watch"
  env       = "prod"
  region    = "us-east-1"
  ephemeral = false # prod is persistent

  cost_profile       = "ha"
  private_networking = true # ha: app in private subnets behind NAT
  enable_nat         = true
  multi_az           = true # ha: Multi-AZ RDS (ADR-005 survival); realized in the data stack (#4)
}

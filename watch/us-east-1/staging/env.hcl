# Env-level inputs for watch / staging / us-east-1. Ephemeral: created for a pipeline run
# (blue/green + migration exercise) then `terragrunt destroy`-ed (ADR-015).
locals {
  project   = "watch"
  env       = "staging"
  region    = "us-east-1"
  ephemeral = true # spun up on demand, torn down after

  # NAT on so the escalation/intake Lambdas + the migrate hook (private subnets) can reach
  # Secrets Manager — required for the promote-by-digest pipeline's staging deploy (#20).
  # Single-AZ RDS keeps staging fast/cheap to recreate.
  cost_profile       = "ha"
  private_networking = true
  enable_nat         = true
  multi_az           = false
}

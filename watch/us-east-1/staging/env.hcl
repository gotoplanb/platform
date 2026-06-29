# Env-level inputs for watch / staging / us-east-1. Ephemeral: created for a pipeline run
# (blue/green + migration exercise) then `terragrunt destroy`-ed (ADR-015).
locals {
  project   = "watch"
  env       = "staging"
  region    = "us-east-1"
  ephemeral = true # spun up on demand, torn down after

  cost_profile       = "lean"
  private_networking = false
  enable_nat         = false
  multi_az           = false
}

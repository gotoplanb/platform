# Env-level inputs for watch / staging / us-east-1. Ephemeral: created for a pipeline run
# (blue/green + migration exercise) then `terragrunt destroy`-ed (ADR-015).
locals {
  project   = "watch"
  env       = "staging"
  region    = "us-east-1"
  ephemeral = true # spun up on demand, torn down after

  # Staging mirrors prod's topology (ha) for build/scan/deploy/migrate fidelity (ADR-019).
  # Cost is controlled by ephemerality (destroy / scale-to-0 between ~weekly releases), not
  # by a leaner shape. Smaller, not leaner: single-AZ RDS + fewer/smaller tasks, same topology.
  cost_profile       = "ha"
  private_networking = true
  enable_nat         = true
  multi_az           = false # disposable env — single-AZ is fine
}

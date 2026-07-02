# Telemetry gateway for watch / staging / us-east-1 (platform#19, ADR-016). A per-env Alloy
# collector the app sidecars forward OTLP to; batches and (once #29 lands) exports to the
# Watchtower LGTM slice. Until then forward_endpoint is empty → a debug sink, so the plane is
# valid + verifiable before a backend exists. lean profile (public subnets, follows the app).
# Applies before the app so the app can wire telemetry_gateway_endpoint to the discovery DNS.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id             = "vpc-mock"
    public_subnet_ids  = ["subnet-ma", "subnet-mb"]
    private_subnet_ids = ["subnet-pa", "subnet-pb"]
    app_sg_id          = "sg-app"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}//modules/gateway"
}

inputs = {
  name   = "${local.env.project}-${local.env.env}"
  region = local.env.region

  private_networking = local.env.private_networking
  vpc_id             = dependency.network.outputs.vpc_id
  public_subnet_ids  = dependency.network.outputs.public_subnet_ids
  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  app_sg_id          = dependency.network.outputs.app_sg_id

  # No backend wired yet (#29) → debug sink. Warm-minimal: one task while telemetry is exercised.
  forward_endpoint = ""
  tail_sampling    = false
  desired_count    = 1
}

# Tempo trace backend for watch / staging (platform#29, ADR-018). The durable-but-warm end of
# the observability plane: the staging gateway forwards OTLP here; Grafana (../grafana) queries
# it. Co-located in the staging VPC (both warm-standby) so no peering. Owns the shared obs ECS
# cluster + Cloud Map namespace that Grafana reuses.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "network" {
  config_path = "../../network"
  mock_outputs = {
    vpc_id             = "vpc-mock"
    public_subnet_ids  = ["subnet-ma", "subnet-mb"]
    private_subnet_ids = ["subnet-pa", "subnet-pb"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "gateway" {
  config_path                             = "../../gateway"
  mock_outputs                            = { security_group_id = "sg-gw-mock" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}//modules/tempo"
}

inputs = {
  name   = "${local.env.project}-${local.env.env}"
  region = local.env.region

  private_networking = local.env.private_networking
  vpc_id             = dependency.network.outputs.vpc_id
  public_subnet_ids  = dependency.network.outputs.public_subnet_ids
  private_subnet_ids = dependency.network.outputs.private_subnet_ids

  gateway_sg_id = dependency.gateway.outputs.security_group_id

  desired_count = 1
}

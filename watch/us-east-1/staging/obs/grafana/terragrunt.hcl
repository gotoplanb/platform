# Grafana viewer for watch / staging (platform#29, ADR-018). Fronts the Tempo backend
# (../tempo) so app traces are viewable. Reuses the obs cluster + Cloud Map namespace Tempo
# created. Public ALB (staging viewer); warm-minimal.

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
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "tempo" {
  config_path = "../tempo"
  mock_outputs = {
    cluster_arn       = "arn:aws:ecs:us-east-1:000000000000:cluster/mock-obs"
    query_endpoint    = "http://tempo.watch-obs.svc:3200"
    security_group_id = "sg-tempo-mock"
    api_port          = 3200
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

terraform {
  source = "${get_repo_root()}//modules/grafana"
}

inputs = {
  name   = "${local.env.project}-${local.env.env}"
  region = local.env.region

  private_networking = local.env.private_networking
  vpc_id             = dependency.network.outputs.vpc_id
  public_subnet_ids  = dependency.network.outputs.public_subnet_ids
  private_subnet_ids = dependency.network.outputs.private_subnet_ids

  cluster_arn          = dependency.tempo.outputs.cluster_arn
  tempo_query_endpoint = dependency.tempo.outputs.query_endpoint
  tempo_sg_id          = dependency.tempo.outputs.security_group_id
  tempo_api_port       = dependency.tempo.outputs.api_port

  desired_count = 1
}

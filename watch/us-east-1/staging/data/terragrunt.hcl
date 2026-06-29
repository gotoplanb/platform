# Data stack for watch / staging / us-east-1 (platform#4). Lean: single-AZ RDS + single
# Valkey node. Ephemeral — created for a pipeline run then destroyed (ADR-015).

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "network" {
  config_path = "../network"

  mock_outputs = {
    private_subnet_ids = ["subnet-mock-a", "subnet-mock-b"]
    data_sg_id         = "sg-mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}//modules/data"
}

inputs = {
  name               = "${local.env.project}-${local.env.env}"
  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  data_sg_id         = dependency.network.outputs.data_sg_id

  multi_az            = local.env.multi_az # false for staging
  deletion_protection = false
  skip_final_snapshot = true

  tags = { env = local.env.env }
}

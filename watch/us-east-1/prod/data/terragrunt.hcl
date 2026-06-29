# Data stack for watch / prod / us-east-1 (platform#4). RDS Postgres + Valkey in the
# network stack's private subnets, behind its data SG. Multi-AZ per the env toggle.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "network" {
  config_path = "../network"

  # Let `validate`/`plan` run before the network stack is applied.
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

  multi_az = local.env.multi_az

  # Create/destroy test loop (ADR-015): protection OFF so `terragrunt destroy` is clean.
  # Real prod hardening flips these (deletion_protection=true, skip_final_snapshot=false).
  deletion_protection = false
  skip_final_snapshot = true

  tags = { env = local.env.env }
}

# Escalation stack for watch / staging / us-east-1 (platform#7). Same engine as prod.
# NOTE: staging is lean (no NAT); VPC Lambdas can't reach Secrets Manager without NAT or
# interface endpoints. Author/validate now; applying staging escalation needs enable_nat
# (or Secrets Manager/STS VPC endpoints added to the network stack).

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    private_subnet_ids = ["subnet-pa", "subnet-pb"]
    app_sg_id          = "sg-app"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "data" {
  config_path = "../data"
  mock_outputs = {
    db_address        = "mock.rds.amazonaws.com"
    db_port           = 5432
    db_name           = "watch"
    db_username       = "watch"
    master_secret_arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock"
    kms_key_arn       = "arn:aws:kms:us-east-1:000000000000:key/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "config" {
  config_path = "../config"
  mock_outputs = {
    django_secret_key_param_arn = "arn:aws:ssm:us-east-1:000000000000:parameter/mock-django"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

terraform {
  source = "${get_repo_root()}//modules/escalation"
}

inputs = {
  name   = "${local.env.project}-${local.env.env}"
  env    = local.env.env
  region = local.env.region

  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  app_sg_id          = dependency.network.outputs.app_sg_id

  db_address           = dependency.data.outputs.db_address
  db_port              = dependency.data.outputs.db_port
  db_name              = dependency.data.outputs.db_name
  db_username          = dependency.data.outputs.db_username
  db_master_secret_arn = dependency.data.outputs.master_secret_arn
  db_kms_key_arn       = dependency.data.outputs.kms_key_arn

  django_secret_key_param_arn = dependency.config.outputs.django_secret_key_param_arn

  tags = { env = local.env.env }
}

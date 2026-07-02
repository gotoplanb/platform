# Observability stack for watch / prod / us-east-1 (platform#11). ALB 5xx alarms (deploy
# gate) + masked log drains. The escalation alarm lives in #7; these add the ALB signals
# the blue/green deploy (#10) rolls back on.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "app" {
  config_path = "../app"
  mock_outputs = {
    alb_arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:loadbalancer/app/watch-prod/abc123"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

terraform {
  source = "${get_repo_root()}//modules/observability"
}

inputs = {
  name    = "${local.env.project}-${local.env.env}"
  env     = local.env.env
  alb_arn = dependency.app.outputs.alb_arn
  tags    = { env = local.env.env }
}

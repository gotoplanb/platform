# Secrets + AppConfig flags for watch / staging / us-east-1 (platform#5). Staging runs the
# release flag ON to exercise the new path before it reaches prod (ADR-003 both-branches).

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${get_repo_root()}//modules/secrets-appconfig"
}

inputs = {
  name   = "${local.env.project}-${local.env.env}"
  env    = local.env.env
  region = local.env.region

  flags = {
    new_triage_ui            = true # exercise the new UI in staging first
    auto_route_on_escalation = true
    devops_agent             = "off"
  }

  tags = { env = local.env.env }
}

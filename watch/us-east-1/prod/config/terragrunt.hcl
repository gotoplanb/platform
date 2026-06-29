# Secrets + AppConfig flags for watch / prod / us-east-1 (platform#5). Self-contained:
# SSM SecureStrings + the AppConfig application/profile/hosted-config for this env.

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
    new_triage_ui            = false # release flag: off in prod until proven in staging
    auto_route_on_escalation = true
    devops_agent             = "off" # operational toggle (ADR-014); work flips prod to "on"
  }

  tags = { env = local.env.env }
}

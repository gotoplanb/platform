# Frontend stack for watch / prod / us-east-1 (platform#9). S3 + CloudFront status page.
# No stack dependencies (the SPA polls /api/status cross-origin; #13 adds the domain/cert).

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "app" {
  config_path = "../app"
  mock_outputs = {
    alb_dns_name = "watch-prod-mock.us-east-1.elb.amazonaws.com"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}//modules/frontend"
}

inputs = {
  name = "${local.env.project}-${local.env.env}"
  env  = local.env.env
  # Proxy /api/* to the ALB so the HTTPS status page is same-origin (no mixed-content/CORS).
  api_origin_domain = dependency.app.outputs.alb_dns_name
  tags              = { env = local.env.env }
}

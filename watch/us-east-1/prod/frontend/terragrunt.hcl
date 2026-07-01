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

dependency "cert" {
  config_path                             = "../cert"
  mock_outputs                            = { certificate_arn = "arn:aws:acm:us-east-1:000000000000:certificate/mock" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}//modules/frontend"
}

inputs = {
  name = "${local.env.project}-${local.env.env}"
  env  = local.env.env
  # /api proxy retired (#13): the status page fetches the API directly from its own HTTPS
  # domain (watch.davestanton.com, CORS). No ALB origin / /api behavior on CloudFront.
  api_origin_domain = ""

  # Custom domain + HTTPS (#13): status.davestanton.com on the cert, ARN from ../cert (#35).
  aliases             = ["status.davestanton.com"]
  acm_certificate_arn = dependency.cert.outputs.certificate_arn

  tags = { env = local.env.env }
}

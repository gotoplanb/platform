# Frontend stack for watch / staging / us-east-1 (platform#9). S3 + CloudFront status page.
# Custom domain status-stg.davestanton.com on the staging cert (#34) so the page is HTTPS and
# can fetch the app (watch-stg) cross-origin without mixed-content.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

# Cert ARN from the staging cert stack (avoids a by-domain lookup / dependency cycle, #34).
dependency "cert" {
  config_path                             = "../cert"
  mock_outputs                            = { certificate_arn = "arn:aws:acm:us-east-1:000000000000:certificate/mock" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

terraform {
  source = "${get_repo_root()}//modules/frontend"
}

inputs = {
  name = "${local.env.project}-${local.env.env}"
  env  = local.env.env

  # Status page fetches the API directly (CORS) from its own HTTPS domain — no /api proxy.
  api_origin_domain   = ""
  aliases             = ["status-stg.davestanton.com"]
  acm_certificate_arn = dependency.cert.outputs.certificate_arn

  tags = { env = local.env.env }
}

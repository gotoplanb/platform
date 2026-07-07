# API DNS record for watch / staging / us-east-1 (platform#34). watch-stg.<domain> CNAME -> ALB.
# The status-stg.<domain> -> CloudFront record is a SEPARATE stack (../dns-status) so the CloudFront
# new-account verification hold (ADR-020) can't block the API hostname. Mirrors prod/dns for
# stg↔prod structural parity. ACM cert lives in ../cert. Only the watch-stg. record here — never the
# apex. Needs CLOUDFLARE_API_TOKEN.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
  # Deep merge so this stack's versions.tf (aws + cloudflare) overrides the root's aws-only one.
  merge_strategy = "deep"
}

# Add the cloudflare provider alongside aws (one required_providers block per module).
generate "versions" {
  path      = "versions.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.6"
      required_providers {
        aws        = { source = "hashicorp/aws", version = "~> 6.0" }
        cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.0" }
      }
    }
  EOF
}

dependency "app" {
  config_path                             = "../app"
  mock_outputs                            = { alb_dns_name = "watch-staging-mock.us-east-1.elb.amazonaws.com" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

terraform {
  source = "${get_repo_root()}//modules/dns-records" # cert split out to ../cert
}

inputs = {
  zone_name    = "davestanton.com"
  app_hostname = "watch-stg.davestanton.com"

  alb_dns_name = dependency.app.outputs.alb_dns_name
  # cloudfront_domain intentionally unset -> only the app record here (status is ../dns-status).
}

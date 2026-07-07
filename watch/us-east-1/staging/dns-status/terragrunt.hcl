# Status-page DNS record for watch / staging / us-east-1 (ADR-020). status-stg.<domain> CNAME -> the
# frontend CloudFront distribution. Split from ../dns (the API record) so the CloudFront
# new-account verification hold can't block watch-stg.<domain>. Mirrors prod/dns-status for
# stg↔prod structural parity. This stack stays blocked until staging/frontend applies (i.e. until
# AWS lifts the CloudFront hold); the API stays reachable regardless. Only the status-stg. record
# here — never the apex. Needs CLOUDFLARE_API_TOKEN.

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

dependency "frontend" {
  config_path                             = "../frontend"
  mock_outputs                            = { distribution_domain_name = "dmock.cloudfront.net" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

terraform {
  source = "${get_repo_root()}//modules/dns-records"
}

inputs = {
  zone_name       = "davestanton.com"
  status_hostname = "status-stg.davestanton.com"

  cloudfront_domain = dependency.frontend.outputs.distribution_domain_name
  # alb_dns_name intentionally unset -> only the status record here (app is ../dns).
}

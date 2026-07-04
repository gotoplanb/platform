# Staging app/status CNAMEs -> staging ALB / CloudFront (platform#34). Depends on staging/app
# + staging/frontend for the targets; the cert is a separate stack (../cert). teardown.sh
# drops these two records (they point at destroyed resources) and keeps the cert.
# Needs CLOUDFLARE_API_TOKEN in the env.

include "root" {
  path           = find_in_parent_folders("terragrunt.hcl")
  merge_strategy = "deep"
}

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

dependency "frontend" {
  config_path                             = "../frontend"
  mock_outputs                            = { distribution_domain_name = "dmock.cloudfront.net" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

terraform {
  source = "${get_repo_root()}//modules/dns-records"
}

inputs = {
  zone_name         = "davestanton.com"
  app_hostname      = "watch-stg.davestanton.com"
  alb_dns_name      = dependency.app.outputs.alb_dns_name
  status_hostname   = "status-stg.davestanton.com"
  # Decoupled from the CloudFront hold (ADR-020): the status record is gated on this being set, so
  # tolerate the frontend stack having no outputs yet (CloudFront verification pending) — create just
  # the app CNAME now; the status CNAME lands once CloudFront exists.
  cloudfront_domain = try(dependency.frontend.outputs.distribution_domain_name, "")
}

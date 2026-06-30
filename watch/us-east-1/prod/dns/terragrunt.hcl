# DNS + TLS for watch / prod / us-east-1 (platform#13). ACM cert + Cloudflare subdomain
# records for davestanton.com. Only creates watch./status./ACM-validation records — never
# the apex or existing records. Needs CLOUDFLARE_API_TOKEN in the env (set -a; source .env).

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
  mock_outputs                            = { alb_dns_name = "watch-prod-mock.us-east-1.elb.amazonaws.com" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "frontend" {
  config_path                             = "../frontend"
  mock_outputs                            = { distribution_domain_name = "dmock.cloudfront.net" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}//modules/dns-tls"
}

inputs = {
  zone_name       = "davestanton.com"
  app_hostname    = "watch.davestanton.com"
  status_hostname = "status.davestanton.com"

  alb_dns_name      = dependency.app.outputs.alb_dns_name
  cloudfront_domain = dependency.frontend.outputs.distribution_domain_name
}

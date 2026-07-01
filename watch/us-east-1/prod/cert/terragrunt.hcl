# Prod ACM cert for watch + status.davestanton.com (platform#35). Split out of prod/dns to
# match staging and break the app<->dns bootstrap cycle. The cert + validation records are
# MIGRATED from prod/dns via import (not recreated) — see the #35 runbook. Kept across
# teardowns like staging's cert. Needs CLOUDFLARE_API_TOKEN in the env.

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

terraform {
  source = "${get_repo_root()}//modules/acm-cert"
}

inputs = {
  zone_name       = "davestanton.com"
  app_hostname    = "watch.davestanton.com"
  status_hostname = "status.davestanton.com"
  tags            = { env = "prod" }
}

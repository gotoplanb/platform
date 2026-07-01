# Staging ACM cert for watch-stg + status-stg (platform#34). Its OWN stack, applied before
# staging/app + staging/frontend (which take its ARN) — breaks the app<->dns bootstrap cycle.
# Kept across teardowns (like prod's cert) to avoid revalidation each ephemeral cycle.
# Needs CLOUDFLARE_API_TOKEN in the env (create.sh/teardown.sh source .env).

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
  # Deep merge so this stack's versions.tf (aws + cloudflare) overrides the root's aws-only one.
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
  app_hostname    = "watch-stg.davestanton.com"
  status_hostname = "status-stg.davestanton.com"
  tags            = { env = "staging" }
}

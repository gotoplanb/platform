# Frontend stack for watch / prod / us-east-1 (platform#9). S3 + CloudFront status page.
# No stack dependencies (the SPA polls /api/status cross-origin; #13 adds the domain/cert).

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${get_repo_root()}//modules/frontend"
}

inputs = {
  name = "${local.env.project}-${local.env.env}"
  env  = local.env.env
  tags = { env = local.env.env }
}

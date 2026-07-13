# Shared ECR for watch / us-east-1 (platform#20). Region-level (not per-env): both staging
# and prod pull the SAME repo so a single built+scanned digest is promoted across envs.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  acct = read_terragrunt_config(find_in_parent_folders("accounts.hcl")).locals
}

terraform {
  source = "${get_repo_root()}//modules/ecr"
}

inputs = {
  name = "watch"
  tags = { scope = "shared", env = "platform" }

  # Cross-account promote-by-digest (ADR-020): let watch-prod pull. Only when prod is a SEPARATE
  # account — in the single-account topology prod pulls as the repo's own account and needs no grant.
  pull_account_ids = local.acct.has_prod ? [local.acct.prod_account_id] : []
}

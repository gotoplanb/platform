# Shared ECR for watch / us-east-1 (platform#20). Region-level (not per-env): both staging
# and prod pull the SAME repo so a single built+scanned digest is promoted across envs.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/ecr"
}

inputs = {
  name = "watch"
  tags = { scope = "shared", env = "platform" }

  # Cross-account promote-by-digest (ADR-020): let watch-prod pull. compact() drops the empty
  # string when WATCH_PROD_ACCOUNT_ID is unset, so this is a no-op until the split is cut over.
  pull_account_ids = compact([get_env("WATCH_PROD_ACCOUNT_ID", "")])
}

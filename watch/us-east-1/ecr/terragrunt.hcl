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
}

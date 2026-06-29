# GitHub OIDC + deploy roles (platform#2). Account-global (IAM is not per-region/env),
# so it lives under account/ rather than watch/<region>/<env>/. First stack to use the
# S3 backend created by ./bootstrap.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/github-oidc"
}

inputs = {
  github_org   = "gotoplanb"
  repo         = "platform" # the IaC repo; watch's app deploy goes via CodePipeline (#10), not OIDC
  apply_branch = "main"
  name_prefix  = "gha"
}

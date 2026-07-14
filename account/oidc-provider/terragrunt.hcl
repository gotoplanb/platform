# The hub account's GitHub federation entry (platform#57). Owned here, alone, because an IAM OIDC
# provider is an account-global singleton — one per URL per account. account/github-oidc's roles
# (gha-plan / gha-apply, for the PLATFORM repo) consume its ARN.
#
# Set WATCH_GITHUB_OIDC_EXISTS=1 if this account ALREADY federates GitHub Actions (very likely in an
# existing org): we then adopt the provider instead of creating it. Never fight an adopter's CI for
# ownership of a singleton — creating it would 409, and destroying it would break their pipelines.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/oidc-provider"
}

inputs = {
  create = get_env("WATCH_GITHUB_OIDC_EXISTS", "0") != "1"
  tags   = { project = get_env("WATCH_PROJECT", "watch"), env = "platform" }
}

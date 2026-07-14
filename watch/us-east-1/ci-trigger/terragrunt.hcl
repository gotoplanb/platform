# OIDC role for gotoplanb/watch's GitHub Actions to start the pipeline (platform#24). Persistent
# (kept across teardowns like the connection) — the role name + pipeline ARN are stable, so it
# survives pipeline recreates. teardown.sh never destroys it.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  acct = read_terragrunt_config(find_in_parent_folders("accounts.hcl")).locals
}

terraform {
  source = "${get_repo_root()}//modules/ci-pipeline-trigger"
}

# Ordering only (no outputs crossed): whichever of these owns this account's federation entry must
# exist before the role that trusts it. In the two-member topologies that is member-oidc/nonprod; in
# single-account, nonprod IS the hub and account/oidc-provider owns it and member-oidc is a no-op.
dependencies {
  paths = ["../../../account/oidc-provider", "../../../member-oidc/nonprod"]
}

inputs = {
  name = "watch-ci-trigger"

  # This module CONSUMES the provider; it no longer creates one (platform#57). The ARN is fully
  # determined by the account and the URL, so it needs no cross-account dependency output.
  oidc_provider_arn = "arn:aws:iam::${local.acct.nonprod_account_id}:oidc-provider/token.actions.githubusercontent.com"

  github_org    = "gotoplanb"
  repo          = "watch"
  pipeline_name = "watch"
  region        = "us-east-1"
  tags          = { project = "watch", env = "platform" }
}

# The pipeline account's GitHub federation entry (platform#57).
#
# OIDC federation is same-account: the watch repo's workflow assumes watch-ci-trigger to start the
# pipeline, so the provider must live in the account the pipeline lives in. Post-split that is
# nonprod, which is why a second provider exists at all — it is NOT a duplicate of the hub's. The
# hub's provider federates the PLATFORM repo (gha-plan/gha-apply); this one federates the WATCH repo
# (StartPipelineExecution only). Prod has NO provider and never will: nothing in GitHub reaches prod
# directly — the nonprod pipeline does, by assuming watch-prod-deploy.
#
# create is false when the pipeline account is NOT a separate account (single-account topology): the
# provider is then the hub's, already owned by account/oidc-provider, and this stack is a deliberate
# no-op rather than a second owner racing for the same singleton.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  acct = read_terragrunt_config(find_in_parent_folders("accounts.hcl")).locals
}

terraform {
  source = "${get_repo_root()}//modules/oidc-provider"
}

inputs = {
  create = local.acct.has_nonprod && get_env("WATCH_GITHUB_OIDC_EXISTS", "0") != "1"
  tags   = { project = get_env("WATCH_PROJECT", "watch"), env = "platform" }
}

# OIDC role for gotoplanb/watch's GitHub Actions to start the pipeline (platform#24). Persistent
# (kept across teardowns like the connection) — the role name + pipeline ARN are stable, so it
# survives pipeline recreates. teardown.sh never destroys it.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/ci-pipeline-trigger"
}

inputs = {
  name = "watch-ci-trigger"
  # oidc_provider_arn omitted (empty) -> the module self-provisions the GitHub OIDC provider in this
  # account. Required post-split (ADR-020): the pipeline is in nonprod, so its trigger role + OIDC
  # provider must be here too (federation is same-account); the shared management provider can't be
  # trusted cross-account.
  github_org    = "gotoplanb"
  repo          = "watch"
  pipeline_name = "watch"
  region        = "us-east-1"
  tags          = { project = "watch", env = "platform" }
}

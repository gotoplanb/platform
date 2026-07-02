# OIDC role for gotoplanb/watch's GitHub Actions to start the pipeline (platform#24). Persistent
# (kept across teardowns like the connection) — the role name + pipeline ARN are stable, so it
# survives pipeline recreates. teardown.sh never destroys it.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

dependency "oidc" {
  config_path                             = "../../../account/github-oidc"
  mock_outputs                            = { oidc_provider_arn = "arn:aws:iam::000000000000:oidc-provider/token.actions.githubusercontent.com" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

terraform {
  source = "${get_repo_root()}//modules/ci-pipeline-trigger"
}

inputs = {
  name              = "watch-ci-trigger"
  oidc_provider_arn = dependency.oidc.outputs.oidc_provider_arn
  github_org        = "gotoplanb"
  repo              = "watch"
  pipeline_name     = "watch"
  region            = "us-east-1"
  tags              = { project = "watch", env = "platform" }
}

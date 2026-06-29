# platform repo as code (platform#15). The IaC repo whose GitHub Actions assume the OIDC
# roles from account/github-oidc (#2) — exposed here as repo Actions variables so CI uses
# role ARNs, never static AWS keys (ADR-004). State writes need a write-capable AWS
# profile + GITHUB_TOKEN.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
  # Deep merge so this stack's `generate "versions"` overrides the root's aws-only one.
  merge_strategy = "deep"
}

locals {
  common = read_terragrunt_config("${get_terragrunt_dir()}/../common.hcl").locals
}

dependency "oidc" {
  config_path = "../../account/github-oidc"

  mock_outputs = {
    plan_role_arn  = "arn:aws:iam::000000000000:role/mock-plan"
    apply_role_arn = "arn:aws:iam::000000000000:role/mock-apply"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}//modules/github-repo"
}

# Override the root's aws-only versions.tf to also require the github provider (only one
# required_providers block is allowed per module).
generate "versions" {
  path      = "versions.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      required_version = ">= 1.6"
      required_providers {
        aws    = { source = "hashicorp/aws", version = "~> 6.0" }
        github = { source = "integrations/github", version = "~> 6.0" }
      }
    }
  EOF
}

inputs = {
  repo         = "platform"
  github_owner = local.common.github_owner
  description  = "GoToPlanB cloud infrastructure as code (Terragrunt/OpenTofu) for AWS, GitHub, and Cloudflare — the cloud counterpart to dev-infrastructure"

  has_wiki = false

  labels         = local.common.labels
  manage_ruleset = true

  # CI assumes these via OIDC (no static keys). The required status check (the CodeBuild
  # gate) is wired in #10 by setting required_status_checks here.
  actions_variables = {
    AWS_PLAN_ROLE_ARN  = dependency.oidc.outputs.plan_role_arn
    AWS_APPLY_ROLE_ARN = dependency.oidc.outputs.apply_role_arn
  }
}

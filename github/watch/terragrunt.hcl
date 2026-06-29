# watch repo as code (platform#15). The app repo; deploys via CodePipeline (#10), so no
# OIDC role variables here. State writes need a write-capable AWS profile + GITHUB_TOKEN.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
  # Deep merge so this stack's `generate "versions"` overrides the root's aws-only one.
  merge_strategy = "deep"
}

locals {
  common = read_terragrunt_config("${get_terragrunt_dir()}/../common.hcl").locals
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
  repo         = "watch"
  github_owner = local.common.github_owner
  description  = "Incident intake & tiered-escalation platform (Watch v1)."

  has_wiki = true # watch keeps its wiki

  labels         = local.common.labels
  manage_ruleset = true
}

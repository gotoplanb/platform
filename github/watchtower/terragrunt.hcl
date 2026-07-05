# watchtower repo as code (platform#15). The self-hosted observability + code-quality platform
# (Grafana/Tempo/SonarQube) Watch exports telemetry to. Managed here for label/ruleset/setting
# parity with watch + platform — all three are versioned together. No CI OIDC role variables (it
# isn't deployed by the CodePipeline). State writes need a write-capable AWS profile + GITHUB_TOKEN.

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
  repo         = "watchtower"
  github_owner = local.common.github_owner
  description  = "Self-hosted observability + code-quality platform (Grafana/Tempo/SonarQube) — the telemetry backend Watch exports to."

  has_wiki = true # preserve watchtower's existing wiki

  labels         = local.common.labels
  manage_ruleset = true
}

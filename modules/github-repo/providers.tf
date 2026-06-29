# The github provider config for this stack. required_providers (github source) is added
# to the terragrunt-generated versions.tf by the stack's `generate "versions"` override —
# Terraform allows only one required_providers block per module, so it can't live here.
# Token is read from GITHUB_TOKEN in the env (`set -a; source .env; set +a`) — never committed.
provider "github" {
  owner = var.github_owner
}

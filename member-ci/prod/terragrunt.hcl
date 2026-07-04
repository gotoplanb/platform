# Read-only CI role in the prod member account (ADR-020 hardening). Assumed by the management
# gha-plan OIDC role so `terragrunt plan` on a PR can read prod without any mutate rights.
# Persistent — routed to prod by the root map (member-ci/prod), not part of the disposable estate,
# so teardown never touches it. Apply path stays OrganizationAccountAccessRole (admin).

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/member-ci-role"
}

inputs = {
  name = "watch-ci-plan"
  # The management-account gha-plan role (this stack's config is evaluated with base = management
  # creds, so get_aws_account_id() is the management account — no hardcoded id in this public repo).
  trusted_plan_role_arn = "arn:aws:iam::${get_aws_account_id()}:role/gha-plan"
  tags                  = { project = "watch", env = "platform" }
}

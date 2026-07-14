# GitHub OIDC + deploy roles (platform#2). Account-global (IAM is not per-region/env),
# so it lives under account/ rather than watch/<region>/<env>/. First stack to use the
# S3 backend created by ./bootstrap.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  acct    = read_terragrunt_config(find_in_parent_folders("accounts.hcl")).locals
  project = get_env("WATCH_PROJECT", "watch")
}

terraform {
  source = "${get_repo_root()}//modules/github-oidc"
}

# The hub's GitHub federation entry is owned by account/oidc-provider, not by this stack (platform#57).
# Ordering only: the ARN is fully determined by the account and the URL, so it needs no output.
dependencies {
  paths = ["../oidc-provider"]
}

inputs = {
  oidc_provider_arn = "arn:aws:iam::${local.acct.current}:oidc-provider/token.actions.githubusercontent.com"

  github_org   = "gotoplanb"
  repo         = "platform" # the IaC repo; watch's app deploy goes via CodePipeline (#10), not OIDC
  apply_branch = "main"
  name_prefix  = "gha"

  # Cross-account plan (ADR-020): let gha-plan assume the read-only watch-ci-plan role in each
  # member (created by member-ci/<env>). Built from the member ids in .env; empty in single-account
  # mode -> no policy. Apply keeps chaining through OrganizationAccountAccessRole (admin).
  member_plan_role_arns = compact([
    local.acct.has_nonprod ? "arn:aws:iam::${local.acct.nonprod_account_id}:role/watch-ci-plan" : "",
    local.acct.has_prod ? "arn:aws:iam::${local.acct.prod_account_id}:role/watch-ci-plan" : "",
  ])

  # The apply path (ADR-044): gha-apply may ASSUME the provisioner — here and in each member — and do
  # nothing else. It used to hold AdministratorAccess. Empty list until account/provisioner and
  # member-iam/* are applied, which keeps the legacy admin attachment so CI never breaks mid-migration.
  provisioner_role_arns = compact([
    "arn:aws:iam::${local.acct.current}:role/${local.project}-provisioner",
    local.acct.has_nonprod ? "arn:aws:iam::${local.acct.nonprod_account_id}:role/${local.project}-provisioner" : "",
    local.acct.has_prod ? "arn:aws:iam::${local.acct.prod_account_id}:role/${local.project}-provisioner" : "",
  ])
}

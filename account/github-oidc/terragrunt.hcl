# GitHub OIDC + deploy roles (platform#2). Account-global (IAM is not per-region/env),
# so it lives under account/ rather than watch/<region>/<env>/. First stack to use the
# S3 backend created by ./bootstrap.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/github-oidc"
}

inputs = {
  github_org   = "gotoplanb"
  repo         = "platform" # the IaC repo; watch's app deploy goes via CodePipeline (#10), not OIDC
  apply_branch = "main"
  name_prefix  = "gha"

  # Cross-account plan (ADR-020): let gha-plan assume the read-only watch-ci-plan role in each
  # member (created by member-ci/<env>). Built from the member ids in .env; empty in single-account
  # mode -> no policy. Apply keeps chaining through OrganizationAccountAccessRole (admin).
  member_plan_role_arns = compact([
    get_env("WATCH_NONPROD_ACCOUNT_ID", "") != "" ? "arn:aws:iam::${get_env("WATCH_NONPROD_ACCOUNT_ID", "")}:role/watch-ci-plan" : "",
    get_env("WATCH_PROD_ACCOUNT_ID", "") != "" ? "arn:aws:iam::${get_env("WATCH_PROD_ACCOUNT_ID", "")}:role/watch-ci-plan" : "",
  ])

  # The apply path (ADR-044): gha-apply may ASSUME the provisioner — here and in each member — and do
  # nothing else. It used to hold AdministratorAccess. Empty list until account/provisioner and
  # member-iam/* are applied, which keeps the legacy admin attachment so CI never breaks mid-migration.
  provisioner_role_arns = compact([
    "arn:aws:iam::${get_aws_account_id()}:role/${get_env("WATCH_PROJECT", "watch")}-provisioner",
    get_env("WATCH_NONPROD_ACCOUNT_ID", "") != "" ? "arn:aws:iam::${get_env("WATCH_NONPROD_ACCOUNT_ID", "")}:role/${get_env("WATCH_PROJECT", "watch")}-provisioner" : "",
    get_env("WATCH_PROD_ACCOUNT_ID", "") != "" ? "arn:aws:iam::${get_env("WATCH_PROD_ACCOUNT_ID", "")}:role/${get_env("WATCH_PROJECT", "watch")}-provisioner" : "",
  ])
}

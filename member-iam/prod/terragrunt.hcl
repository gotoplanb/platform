# The provisioner role + permissions boundary INSIDE the prod member account (ADR-044).
#
# Trusted by the hub account root, so the hub identity that runs `make live` (or the gha-apply OIDC
# role) can assume it — replacing the admin OrganizationAccountAccessRole as the apply path. Set
# WATCH_MEMBER_ROLE_NAME=watch-provisioner and every cross-account write in this repo goes through
# the fenced role instead of admin.
#
# Applied ONCE with an admin identity (the chicken-and-egg is unavoidable: something with IAM rights
# has to mint the role that then needs no admin). Persistent — teardown never touches it.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/provisioner-role"
}

inputs = {
  project = get_env("WATCH_PROJECT", "watch")

  # The hub account root: this stack's config is evaluated with hub base creds, so get_aws_account_id()
  # is the hub — no hardcoded account id in this public repo. Root (rather than a named role) lets the
  # hub's own IAM decide WHICH hub identity may assume it, which is the security team's call, not ours.
  trusted_principal_arns = ["arn:aws:iam::${get_aws_account_id()}:root"]

  tags = { project = get_env("WATCH_PROJECT", "watch"), env = "prod" }
}

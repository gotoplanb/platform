# The provisioner role + permissions boundary in the HUB account (ADR-044).
#
# This is the stack that replaces bootstrap-admin. It is applied ONCE, by an admin identity
# (`watch-bootstrap`, or your org's break-glass), and thereafter everything — `make live`,
# `make teardown`, CI apply — runs as `watch-provisioner`, whose powers are exactly the four
# policy documents in policies/ and no more.
#
# It is deliberately NOT part of the disposable estate: `make teardown` never touches it (it is
# not in teardown.sh's ENV_STACKS), because destroying the identity that does the destroying is
# a bad afternoon.
#
# In a SINGLE-ACCOUNT estate this is the only provisioner stack there is — the hub is the estate.
# In a two-member estate, member-iam/{nonprod,prod} mint the same role inside each member, trusting
# this account.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

terraform {
  source = "${get_repo_root()}//modules/provisioner-role"
}

inputs = {
  project = get_env("WATCH_PROJECT", "watch")

  # The hub always owns its own provisioner + boundary. Stated explicitly because the member-iam
  # stacks make the same claim conditionally, and in single-account all three target this account —
  # exactly one of them may create the names (platform#58).
  create = true

  # Who may assume the provisioner in the hub. The account root delegates the decision to that
  # account's own IAM (an admin can then grant sts:AssumeRole to a human, an SSO permission set, or
  # the gha-apply OIDC role) — which is what a security team will want, rather than us hardcoding a
  # principal they have never heard of.
  trusted_principal_arns = ["arn:aws:iam::${get_aws_account_id()}:root"]

  tags = { project = get_env("WATCH_PROJECT", "watch"), env = "platform" }
}

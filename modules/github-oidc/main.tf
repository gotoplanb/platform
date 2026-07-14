# GitHub Actions OIDC + deploy roles (platform#2). Lets GitHub Actions in the IaC repo
# assume short-lived AWS roles via OIDC — no long-lived keys. Two roles:
#   - <prefix>-plan  : ReadOnly, assumable from ANY ref (terragrunt plan on PRs)
#   - <prefix>-apply : write, assumable ONLY from the apply branch (terragrunt apply on merge)
# The trust condition (repo + ref) is the security boundary. Once this is wired into CI,
# the temporary `watch-bootstrap` access key is disabled (ADR-004 / aws-operating-principles).

#
# The OIDC provider itself is NOT created here (platform#57). It is an account-global singleton, so
# it is owned by one explicit stack per federating account (modules/oidc-provider) and consumed by
# ARN — this module and modules/ci-pipeline-trigger were both creating one, which only worked
# because they happened to land in different accounts.

variable "oidc_provider_arn" {
  description = "ARN of this account's GitHub federation entry, from the account's oidc-provider stack."
  type        = string
}

locals {
  sub_any   = "repo:${var.github_org}/${var.repo}:*"
  sub_apply = "repo:${var.github_org}/${var.repo}:ref:refs/heads/${var.apply_branch}"
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.sub_any]
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.sub_apply]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.name_prefix}-plan"
  description          = "GitHub Actions: terragrunt plan (read-only, any ref)."
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  permissions_boundary = var.permissions_boundary != "" ? var.permissions_boundary : null
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Cross-account plan (ADR-020): ReadOnlyAccess excludes sts:AssumeRole, so grant the plan role a
# NARROW assume on exactly the members' read-only watch-ci-plan roles — never the admin
# OrganizationAccountAccessRole. Keeps the plan path read-only in every account.
resource "aws_iam_role_policy" "plan_assume_members" {
  count = length(var.member_plan_role_arns) > 0 ? 1 : 0
  name  = "assume-member-plan-roles"
  role  = aws_iam_role.plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = var.member_plan_role_arns
    }]
  })
}

resource "aws_iam_role" "apply" {
  name                 = "${var.name_prefix}-apply"
  description          = "GitHub Actions: terragrunt apply (write, ${var.apply_branch} only)."
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  permissions_boundary = var.permissions_boundary != "" ? var.permissions_boundary : null
  max_session_duration = 3600
}

# The CI apply path holds NO powers of its own (ADR-044). It used to hold AdministratorAccess —
# "broad for now, the OIDC trust is the real boundary" — which is exactly the sentence a security
# team refuses to sign. Now it can do precisely one thing: BECOME the provisioner, whose powers are
# the four reviewable documents in policies/. Anything CI can do, the security team has already read.
#
# It is boundary-fenced like any other estate role, which it can afford to be: assuming a role is
# not an IAM write, so the boundary's "never grant yourself more IAM" deny costs it nothing.
resource "aws_iam_role_policy" "apply_assume_provisioner" {
  count = length(var.provisioner_role_arns) > 0 ? 1 : 0
  name  = "assume-provisioner"
  role  = aws_iam_role.apply.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = var.provisioner_role_arns
    }]
  })
}

# Escape hatch for an estate that has NOT adopted the provisioner yet (provisioner_role_arns = []):
# fall back to the old admin attachment rather than shipping a CI role that can do nothing at all.
# Loud on purpose — the plan is that nobody runs this way for long.
resource "aws_iam_role_policy_attachment" "apply_admin_legacy" {
  count      = length(var.provisioner_role_arns) > 0 ? 0 : 1
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

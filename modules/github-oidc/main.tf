# GitHub Actions OIDC + deploy roles (platform#2). Lets GitHub Actions in the IaC repo
# assume short-lived AWS roles via OIDC — no long-lived keys. Two roles:
#   - <prefix>-plan  : ReadOnly, assumable from ANY ref (terragrunt plan on PRs)
#   - <prefix>-apply : write, assumable ONLY from the apply branch (terragrunt apply on merge)
# The trust condition (repo + ref) is the security boundary. Once this is wired into CI,
# the temporary `watch-bootstrap` access key is disabled (ADR-004 / aws-operating-principles).

locals {
  sub_any   = "repo:${var.github_org}/${var.repo}:*"
  sub_apply = "repo:${var.github_org}/${var.repo}:ref:refs/heads/${var.apply_branch}"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS no longer validates this for the well-known GitHub provider, but the field is kept.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
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
      identifiers = [aws_iam_openid_connect_provider.github.arn]
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
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role" "apply" {
  name                 = "${var.name_prefix}-apply"
  description          = "GitHub Actions: terragrunt apply (write, ${var.apply_branch} only)."
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

# Broad for now — Terragrunt creates many resource types. TODO: scope down to per-stack
# policies once the stacks settle. The OIDC trust (repo + branch) is the real boundary.
resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

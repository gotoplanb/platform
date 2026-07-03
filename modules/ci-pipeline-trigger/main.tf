# GitHub Actions OIDC role for the app repo to START the pipeline (platform#24). The native
# CodeConnections push trigger wouldn't deliver events, so the app repo's workflow assumes this
# role and calls StartPipelineExecution instead — trigger-only (CodePipeline still builds/deploys,
# ADR-004). Least-privilege: trust the app repo on ANY ref (so the workflow can later switch from
# main pushes to release tags with no IAM change), permission = StartPipelineExecution on the one
# pipeline.
#
# The trust provider and this role MUST live in the SAME account as the pipeline (OIDC federation is
# same-account). After the multi-account split (ADR-020) the pipeline is in nonprod, which had no
# GitHub OIDC provider — so this module SELF-PROVISIONS one when `oidc_provider_arn` is empty (the
# default). Pass a non-empty ARN to reuse an existing provider (single-account / shared-provider mode).

variable "name" {
  type    = string
  default = "watch-ci-trigger"
}
variable "oidc_provider_arn" {
  type    = string
  default = "" # empty => create the GitHub OIDC provider in this (the pipeline's) account
}
variable "github_org" { type = string }
variable "repo" { type = string }
variable "pipeline_name" { type = string }
variable "region" {
  type    = string
  default = "us-east-1"
}
variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}

# Self-provision the GitHub OIDC provider in this account unless an ARN was supplied. One provider
# per URL per account, so this is the account's single GitHub federation entry.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.oidc_provider_arn == "" ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS no longer validates this for the well-known GitHub provider, but the field is kept.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
  tags = var.tags
}

locals {
  pipeline_arn = "arn:aws:codepipeline:${var.region}:${data.aws_caller_identity.current.account_id}:${var.pipeline_name}"
  provider_arn = var.oidc_provider_arn != "" ? var.oidc_provider_arn : one(aws_iam_openid_connect_provider.github[*].arn)
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.repo}:*"] # any ref — branch or tag
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  description          = "GitHub Actions (${var.github_org}/${var.repo}): start the ${var.pipeline_name} pipeline."
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  tags                 = var.tags
}

data "aws_iam_policy_document" "perms" {
  statement {
    sid       = "StartThePipeline"
    actions   = ["codepipeline:StartPipelineExecution"]
    resources = [local.pipeline_arn]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "start-pipeline"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.perms.json
}

output "role_arn" {
  value = aws_iam_role.this.arn
}

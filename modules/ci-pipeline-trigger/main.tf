# GitHub Actions OIDC role for the app repo to START the pipeline (platform#24). The native
# CodeConnections push trigger wouldn't deliver events, so the app repo's workflow assumes this
# role and calls StartPipelineExecution instead — trigger-only (CodePipeline still builds/deploys,
# ADR-004). Least-privilege: trust the app repo on ANY ref (so the workflow can later switch from
# main pushes to release tags with no IAM change), permission = StartPipelineExecution on the one
# pipeline. Reuses the existing GitHub OIDC provider.

variable "name" {
  type    = string
  default = "watch-ci-trigger"
}
variable "oidc_provider_arn" { type = string }
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

locals {
  pipeline_arn = "arn:aws:codepipeline:${var.region}:${data.aws_caller_identity.current.account_id}:${var.pipeline_name}"
}

data "aws_iam_policy_document" "trust" {
  statement {
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

# Cross-account deploy role (ADR-020) — lives in watch-prod. The nonprod CodePipeline's DeployProd
# action assumes this (action-level role_arn) to run the prod ECS blue/green CodeDeploy in this
# account. Trusts the nonprod (pipeline) account; scoped to CodeDeploy + the ECS/ELB surface
# CodeDeployToECS drives, reading the pipeline artifact (cross-account S3 + KMS), and PassRole for
# the prod ECS task roles.

variable "name" {
  type    = string
  default = "watch-prod-deploy"
}
variable "trusted_account_id" {
  description = "The nonprod (pipeline) account allowed to assume this role."
  type        = string
}
variable "artifact_bucket_arn" {
  type = string
}
variable "artifact_kms_key_arn" {
  type = string
}
variable "pass_role_arns" {
  description = "Prod ECS execution + task role ARNs the deploy may PassRole."
  type        = list(string)
}
variable "tags" {
  type    = map(string)
  default = {}
}

variable "permissions_boundary" {
  description = "Permissions boundary applied to every role this module creates (ADR-044). Empty = none, for estates that have not adopted the fence."
  type        = string
  default     = ""
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.trusted_account_id}:root"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary != "" ? var.permissions_boundary : null
  tags                 = var.tags
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "CodeDeploy"
    actions   = ["codedeploy:*"]
    resources = ["*"]
  }
  statement {
    sid = "EcsAndElb"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeServices",
      # The worker's rolling deploy (platform#61). Everything else here is the blue/green task-set
      # dance, which is why the plain, boring way to deploy a service with no load balancer was
      # never granted, and the worker was never promoted. The ECS deploy provider needs the whole
      # set — it polls tasks to decide the rollout settled, and tags what it creates.
      "ecs:UpdateService",
      "ecs:ListTasks",
      "ecs:TagResource",
      "ecs:UpdateServicePrimaryTaskSet",
      "ecs:CreateTaskSet",
      "ecs:DeleteTaskSet",
      "ecs:DescribeTaskSets",
      "ecs:DescribeTasks",
      "ecs:DescribeTaskDefinition",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:ModifyRule",
      "cloudwatch:DescribeAlarms",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "Artifact"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetBucketLocation"]
    resources = [var.artifact_bucket_arn, "${var.artifact_bucket_arn}/*"]
  }
  statement {
    sid       = "ArtifactKey"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [var.artifact_kms_key_arn]
  }
  statement {
    sid       = "PassEcsRoles"
    actions   = ["iam:PassRole"]
    resources = var.pass_role_arns
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${var.name}-policy"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "role_arn" {
  value = aws_iam_role.this.arn
}

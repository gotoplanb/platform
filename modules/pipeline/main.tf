# Pipeline stack (platform#20, ADR-017) — build once, promote by digest. CodeConnections
# source -> one CodeBuild (gates + image to the shared ECR, pinned by digest) -> CodeDeploy
# to STAGING -> manual approval -> CodeDeploy to PROD, same digest. No CodeBuild in the prod
# path. This file: artifact bucket, GitHub connection, and a per-env migration hook Lambda.

data "aws_caller_identity" "current" {}

locals {
  envs = { staging = var.staging, prod = var.prod }
  # The migration hook runs `ecs run-task` against the env's cluster. Prod's cluster is in
  # watch-prod (cross-account, ADR-020) — deferred, so only staging gets an in-pipeline hook; prod
  # migrations run manually via the cross-account db.sh until the prod hook moves to watch-prod.
  hook_envs = { staging = var.staging }
}

# ---- Artifact bucket --------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name}-pipeline-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = merge(var.tags, { Name = "${var.name}-pipeline" })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Customer-managed key for the artifact bucket. Cross-account artifact decrypt (the prod deploy
# role in watch-prod, ADR-020) REQUIRES a CMK — SSE-S3 can't be shared. The key policy grants the
# prod ACCOUNT root (not the specific role, which doesn't exist yet → invalid principal); the prod
# deploy role's own IAM policy carries the kms:Decrypt half, and cross-account needs both.
locals {
  prod_account_id = var.prod_deploy_role_arn != "" ? element(split(":", var.prod_deploy_role_arn), 4) : ""
}

resource "aws_kms_key" "artifacts" {
  description             = "${var.name} pipeline artifact encryption"
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "AccountRoot"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      }
      ], local.prod_account_id != "" ? [
      {
        Sid       = "CrossAccountArtifactRead"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.prod_account_id}:root" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource  = "*"
      }
    ] : [])
  })
  tags = var.tags
}

resource "aws_kms_alias" "artifacts" {
  name          = "alias/${var.name}-pipeline"
  target_key_id = aws_kms_key.artifacts.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.artifacts.arn
    }
    bucket_key_enabled = true
  }
}

# The GitHub source connection now lives in its own persistent stack (platform#33) and is
# passed in via var.connection_arn — see modules/connection. Keeping it out of this stack is
# what lets the #24 push trigger register (pipeline created against an AVAILABLE connection).

# ---- Per-env migration hook Lambda (BeforeAllowTraffic) ----------------------
# Runs `manage.py migrate` on that env's green task def before its traffic shifts (#12).

data "archive_file" "hook" {
  type        = "zip"
  source_file = "${path.module}/hook/handler.py"
  output_path = "${path.module}/hook/handler.zip"
}

data "aws_iam_policy_document" "hook_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hook" {
  for_each           = local.hook_envs
  name               = "${var.name}-${each.key}-deploy-hook"
  assume_role_policy = data.aws_iam_policy_document.hook_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "hook_basic" {
  for_each   = local.hook_envs
  role       = aws_iam_role.hook[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "hook" {
  for_each = local.hook_envs
  name     = "${var.name}-${each.key}-deploy-hook"
  role     = aws_iam_role.hook[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["codedeploy:PutLifecycleEventHookExecutionStatus"], Resource = "*" },
      { Effect = "Allow", Action = ["ecs:RunTask", "ecs:DescribeTasks", "ecs:DescribeTaskDefinition"], Resource = "*" },
      {
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = [each.value.execution_role_arn, each.value.task_role_arn]
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
    ]
  })
}

# Declared so Lambda reuses it (instead of auto-creating one outside TF) and teardown removes it
# — otherwise /aws/lambda/<fn> orphans on every destroy (platform#38).
resource "aws_cloudwatch_log_group" "hook" {
  for_each          = local.hook_envs
  name              = "/aws/lambda/${var.name}-${each.key}-deploy-hook"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "hook" {
  for_each      = local.hook_envs
  function_name = "${var.name}-${each.key}-deploy-hook"
  role          = aws_iam_role.hook[each.key].arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  timeout       = 600

  filename         = data.archive_file.hook.output_path
  source_code_hash = data.archive_file.hook.output_base64sha256

  environment {
    variables = {
      CLUSTER         = each.value.cluster_name
      TASK_FAMILY     = each.value.task_family
      CONTAINER_NAME  = var.container_name
      SUBNETS         = join(",", each.value.private_subnet_ids)
      SECURITY_GROUPS = each.value.app_sg_id
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-${each.key}-deploy-hook" })
}

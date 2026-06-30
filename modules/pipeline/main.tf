# Pipeline stack (platform#10) — the authoritative CD path (ADR-004): CodeConnections
# source -> CodeBuild (gates + image) -> CodeDeploy ECS blue/green. This file holds the
# artifact bucket, the GitHub connection, and the deploy-hook Lambda.

data "aws_caller_identity" "current" {}

# ---- Artifact bucket --------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name}-pipeline-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # ephemeral test loop (ADR-015): teardown shouldn't block on objects
  tags          = merge(var.tags, { Name = "${var.name}-pipeline" })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---- GitHub source connection ----------------------------------------------
# Created PENDING; complete the one-time OAuth handshake in the console (or `aws
# codestar-connections` / CodeConnections) before the first pipeline run.

resource "aws_codestarconnections_connection" "github" {
  name          = substr("${var.name}-gh", 0, 32)
  provider_type = "GitHub"
  tags          = var.tags
}

# ---- Deploy-hook Lambda (BeforeAllowTraffic / AfterAllowTraffic) ------------

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
  name               = "${var.name}-deploy-hook"
  assume_role_policy = data.aws_iam_policy_document.hook_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "hook_basic" {
  role       = aws_iam_role.hook.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Report hook status back to CodeDeploy (else the deploy stalls).
resource "aws_iam_role_policy" "hook_codedeploy" {
  name = "${var.name}-deploy-hook"
  role = aws_iam_role.hook.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["codedeploy:PutLifecycleEventHookExecutionStatus"]
      Resource = "*"
    }]
  })
}

resource "aws_lambda_function" "hook" {
  function_name = "${var.name}-deploy-hook"
  role          = aws_iam_role.hook.arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  timeout       = 120

  filename         = data.archive_file.hook.output_path
  source_code_hash = data.archive_file.hook.output_base64sha256

  tags = merge(var.tags, { Name = "${var.name}-deploy-hook" })
}

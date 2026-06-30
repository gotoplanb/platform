# The two decision Lambdas (ADR-010): record_token persists the task token + SLA deadline
# to Postgres (waitForTaskToken handler); commit is the SOLE writer of Transitions, calling
# incidents.services.escalate/resolve. Both django.setup() against RDS, so they run in the
# VPC. Code is a placeholder here — the pipeline (#10) ships the Django-bundled package and
# updates the function; lifecycle ignores the code so deploys aren't reverted.

data "archive_file" "placeholder" {
  type        = "zip"
  source_file = "${path.module}/placeholder/handler.py"
  output_path = "${path.module}/placeholder/handler.zip"
}

# ---- Lambda execution role --------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-escalation-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

# ENI management for VPC access + CloudWatch Logs.
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Read the DB master secret + Django secret (the handler fetches at runtime) and decrypt.
resource "aws_iam_role_policy" "lambda_secrets" {
  name = "${var.name}-escalation-secrets"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.db_master_secret_arn
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = var.django_secret_key_param_arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.db_kms_key_arn]
      },
    ]
  })
}

locals {
  lambda_env = {
    DJANGO_SETTINGS_MODULE = "config.settings"
    POSTGRES_HOST          = var.db_address
    POSTGRES_PORT          = tostring(var.db_port)
    POSTGRES_DB            = var.db_name
    POSTGRES_USER          = var.db_username
    DB_MASTER_SECRET_ARN   = var.db_master_secret_arn
    DJANGO_SECRET_KEY_ARN  = var.django_secret_key_param_arn
    AWS_REGION_NAME        = var.region
    # Engine writes go straight to Postgres; flags/cache aren't needed in the Lambda path.
    FLAGS_PROVIDER = "memory"
  }
}

resource "aws_cloudwatch_log_group" "record_token" {
  name              = "/aws/lambda/${var.name}-record-token"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "commit" {
  name              = "/aws/lambda/${var.name}-commit"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "record_token" {
  function_name = "${var.name}-record-token"
  role          = aws_iam_role.lambda.arn
  runtime       = "python3.12"
  handler       = "record_token.handler"
  memory_size   = var.lambda_memory
  timeout       = var.lambda_timeout

  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.app_sg_id]
  }

  environment {
    variables = local.lambda_env
  }

  depends_on = [aws_cloudwatch_log_group.record_token, aws_iam_role_policy_attachment.lambda_vpc]

  # The pipeline (#10) ships the real Django-bundled package; don't revert it.
  lifecycle {
    ignore_changes = [filename, source_code_hash, handler, runtime]
  }

  tags = merge(var.tags, { Name = "${var.name}-record-token" })
}

resource "aws_lambda_function" "commit" {
  function_name = "${var.name}-commit"
  role          = aws_iam_role.lambda.arn
  runtime       = "python3.12"
  handler       = "commit.handler"
  memory_size   = var.lambda_memory
  timeout       = var.lambda_timeout

  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.app_sg_id]
  }

  environment {
    variables = local.lambda_env
  }

  depends_on = [aws_cloudwatch_log_group.commit, aws_iam_role_policy_attachment.lambda_vpc]

  lifecycle {
    ignore_changes = [filename, source_code_hash, handler, runtime]
  }

  tags = merge(var.tags, { Name = "${var.name}-commit" })
}

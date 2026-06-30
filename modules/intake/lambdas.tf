data "aws_caller_identity" "current" {}

locals {
  # The consumer launches the per-incident execution; predict the state machine ARN (#7)
  # the same way the app does, to avoid a cross-stack cycle.
  escalation_state_machine_arn = "arn:aws:states:${var.region}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.name}"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---- Authorizer Lambda (shared-secret check; no VPC, no DB) ------------------

data "archive_file" "authorizer" {
  type        = "zip"
  source_file = "${path.module}/authorizer/authorizer.py"
  output_path = "${path.module}/authorizer/authorizer.zip"
}

resource "aws_iam_role" "authorizer" {
  name               = "${var.name}-intake-authorizer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "authorizer_basic" {
  role       = aws_iam_role.authorizer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "authorizer_ssm" {
  name = "${var.name}-intake-authorizer"
  role = aws_iam_role.authorizer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = var.webhook_secret_param_arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_lambda_function" "authorizer" {
  function_name = "${var.name}-intake-authorizer"
  role          = aws_iam_role.authorizer.arn
  runtime       = "python3.12"
  handler       = "authorizer.handler"
  timeout       = 5

  filename         = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256

  environment {
    variables = {
      WEBHOOK_SECRET_PARAM_NAME = var.webhook_secret_param_name
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-intake-authorizer" })
}

# ---- Consumer Lambda (SQS-triggered Django worker; VPC -> RDS) ---------------

data "archive_file" "consumer" {
  type        = "zip"
  source_file = "${path.module}/consumer/intake_consumer.py"
  output_path = "${path.module}/consumer/handler.zip"
}

resource "aws_iam_role" "consumer" {
  name               = "${var.name}-intake-consumer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "consumer_vpc" {
  role       = aws_iam_role.consumer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "consumer" {
  name = "${var.name}-intake-consumer"
  role = aws_iam_role.consumer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.intake.arn
      },
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
      {
        # Start the per-incident escalation execution (#7).
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = local.escalation_state_machine_arn
      },
    ]
  })
}

resource "aws_lambda_function" "consumer" {
  function_name = "${var.name}-intake-consumer"
  role          = aws_iam_role.consumer.arn
  runtime       = "python3.12"
  handler       = "intake_consumer.handler"
  timeout       = var.lambda_timeout
  memory_size   = 512

  filename         = data.archive_file.consumer.output_path
  source_code_hash = data.archive_file.consumer.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.app_sg_id]
  }

  environment {
    variables = {
      DJANGO_SETTINGS_MODULE       = "config.settings"
      POSTGRES_HOST                = var.db_address
      POSTGRES_PORT                = tostring(var.db_port)
      POSTGRES_DB                  = var.db_name
      POSTGRES_USER                = var.db_username
      DB_MASTER_SECRET_ARN         = var.db_master_secret_arn
      DJANGO_SECRET_KEY_ARN        = var.django_secret_key_param_arn
      AWS_REGION_NAME              = var.region
      FLAGS_PROVIDER               = "memory"
      ESCALATION_STATE_MACHINE_ARN = local.escalation_state_machine_arn
      ESCALATION_LOCAL_MODE        = "0" # use the real Step Functions engine (default is local)
    }
  }

  # The pipeline (#10) ships the Django-bundled package; don't revert it.
  lifecycle {
    ignore_changes = [filename, source_code_hash, handler, runtime]
  }

  tags = merge(var.tags, { Name = "${var.name}-intake-consumer" })
}

resource "aws_lambda_event_source_mapping" "consumer" {
  event_source_arn        = aws_sqs_queue.intake.arn
  function_name           = aws_lambda_function.consumer.arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
}

# Two roles (ADR §4.3):
#   - execution role: ECS pulls the image, resolves the `secrets` block, ships logs.
#   - task role: the running containers' AWS identity (AppConfig Agent now; Step Functions
#     / SQS attach in #7 / #8).

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ---- Execution role ---------------------------------------------------------

resource "aws_iam_role" "execution" {
  name               = "${var.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# SSM SecureStrings (Django/webhook) from the config stack (#5).
resource "aws_iam_role_policy_attachment" "execution_secrets" {
  role       = aws_iam_role.execution.name
  policy_arn = var.secrets_read_policy_arn
}

# The RDS-managed master credential (Secrets Manager) + its CMK.
resource "aws_iam_policy" "db_secret_read" {
  name        = "${var.name}-db-secret-read"
  description = "Execution role: read the RDS master secret for ${var.name}."
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
        Action   = ["kms:Decrypt"]
        Resource = var.db_kms_key_arn
      },
    ]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_db_secret" {
  role       = aws_iam_role.execution.name
  policy_arn = aws_iam_policy.db_secret_read.arn
}

# ---- Task role --------------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

# AppConfig Agent reads the flag profile (#5).
resource "aws_iam_role_policy_attachment" "task_appconfig" {
  role       = aws_iam_role.task.name
  policy_arn = var.appconfig_read_policy_arn
}

# Escalation engine (#7, ADR-007/010): the API starts one execution per incident and
# advances tiers via SendTaskSuccess. StartExecution is scoped to the state machine;
# the SendTask* calls are token-based (resource "*"); DescribeExecution to its executions.
resource "aws_iam_role_policy" "task_escalation" {
  name = "${var.name}-escalation"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = local.escalation_state_machine_arn
      },
      {
        Effect   = "Allow"
        Action   = ["states:DescribeExecution", "states:StopExecution"]
        Resource = "arn:aws:states:${var.region}:${data.aws_caller_identity.current.account_id}:execution:${var.name}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["states:SendTaskSuccess", "states:SendTaskFailure", "states:SendTaskHeartbeat"]
        Resource = "*"
      },
    ]
  })
}

# AI-drafted RCA (ADR-033): the app invokes a Claude Sonnet model on Bedrock. Least-privilege to
# Anthropic Claude foundation models (any region the cross-region inference profile routes to) plus
# this account's inference profiles — NOT bedrock:* on "*". Model *access* is still a separate,
# per-account console grant; this only authorizes the Invoke once access exists.
resource "aws_iam_role_policy" "task_bedrock" {
  name = "${var.name}-bedrock"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/anthropic.claude-*",
          "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*",
        ]
      },
    ]
  })
}

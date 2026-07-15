# Step Functions Standard state machine (ADR-001/007): one execution per incident. The
# ASL is the vendored escalation/statemachine.asl.json with the two Lambda ARNs rendered
# in (replace(), not templatefile() — the ASL comment contains a literal ${...} that
# templatefile would choke on). Creating the state machine validates the definition,
# satisfying the acceptance criterion.

locals {
  definition = replace(
    replace(
      file("${path.module}/statemachine.asl.json"),
      "$${record_token_function_arn}", aws_lambda_function.record_token.arn
    ),
    "$${commit_function_arn}", aws_lambda_function.commit.arn
  )
}

# ---- State machine execution role -------------------------------------------

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name                 = "${var.name}-escalation-sfn"
  assume_role_policy   = data.aws_iam_policy_document.sfn_assume.json
  permissions_boundary = var.permissions_boundary != "" ? var.permissions_boundary : null
  tags                 = var.tags
}

resource "aws_iam_role_policy" "sfn" {
  name = "${var.name}-escalation-sfn"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.record_token.arn, aws_lambda_function.commit.arn]
      },
      {
        # CloudWatch Logs delivery for execution history (these actions require "*").
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies", "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_sfn_state_machine" "this" {
  name     = var.name
  type     = "STANDARD"
  role_arn = aws_iam_role.sfn.arn

  definition = local.definition

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tags = merge(var.tags, { Name = var.name })
}

# The OPERATIONS / on-call signal (ADR-001): a failed execution is a missed escalation (T3 SLA
# elapsed with no resolution, the deliberate EscalationExhausted Fail) OR an engine error. This is
# the escalation-correctness KPI — it pages on-call. It is NOT wired to the deploy gate: a
# legitimately-unresolved incident is a real event, not a broken deploy, and must never roll back a
# deployment (that conflation latched the gate on a single seeded incident — platform#64, ADR-048).
# SNS action is wired in #11.
resource "aws_cloudwatch_metric_alarm" "executions_failed" {
  alarm_name          = "${var.name}-escalation-failed"
  alarm_description   = "Watch escalation executions failed (missed escalation or engine error) — on-call/KPI, NOT the deploy gate."
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.this.arn
  }

  tags = var.tags
}

# The DEPLOY GATE (ADR-048). CodeDeploy rolls back when THIS alarm is active. It watches
# LambdaFunctionsFailed — the decision/commit Lambdas throwing (a broken image, code ahead of the
# schema: the platform#62/#63 family) — which is exactly "this deploy broke the engine". A
# deliberate EscalationExhausted Fail raises no Lambda failure, so a missed incident no longer stops
# deploys. FILL(m1, 0) makes missing data an explicit 0 so the alarm self-resets to OK once the
# Lambdas stop failing; without it a silent AWS/States metric leaves the alarm latched in ALARM and
# the very deploy that would FIX a broken Lambda can never install (the deadlock platform#62 hit).
resource "aws_cloudwatch_metric_alarm" "engine_error" {
  alarm_name          = "${var.name}-escalation-engine-error"
  alarm_description   = "Watch escalation Lambda invocations failed — the deploy gate (a broken engine, not a missed incident)."
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "e1"
    expression  = "FILL(m1, 0)"
    label       = "LambdaFunctionsFailed (missing filled to 0 so the gate self-resets)"
    return_data = true
  }
  metric_query {
    id = "m1"
    metric {
      namespace   = "AWS/States"
      metric_name = "LambdaFunctionsFailed"
      period      = 300
      stat        = "Sum"
      dimensions = {
        StateMachineArn = aws_sfn_state_machine.this.arn
      }
    }
  }

  tags = var.tags
}

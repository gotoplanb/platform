# Smoke stage (platform#… E2E gate): post-deploy Playwright functional test against staging —
# the runtime *functional* gate, complementing DAST (security) and the build-time Sonar (SAST).
# Runs the app repo's e2e/ suite (from the source artifact) against the public watch-stg
# endpoint (no VPC): health -> status -> login -> intake create -> escalate -> T2, so RDS,
# Valkey, Step Functions + commit Lambda, and the status SPA are each exercised. Failure blocks
# the prod promotion. The intake secret is injected from SSM (never in the pipeline definition).

resource "aws_cloudwatch_log_group" "smoke" {
  name              = "/codebuild/${var.name}-smoke"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_iam_role" "smoke" {
  name               = "${var.name}-smoke"
  assume_role_policy = data.aws_iam_policy_document.build_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "smoke" {
  name = "${var.name}-smoke"
  role = aws_iam_role.smoke.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.smoke.arn}:*" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"], Resource = "${aws_s3_bucket.artifacts.arn}/*" },
      # Artifact bucket is SSE-KMS — decrypt to read the build artifact (the SSM kms:Decrypt below is
      # scoped to ssm ViaService for the intake secret, so it doesn't cover the artifact CMK).
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = aws_kms_key.artifacts.arn },
      { Effect = "Allow", Action = ["ssm:GetParameters"], Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.staging_intake_secret_param}" },
      # Decrypt the SecureString only via SSM (scoped by ViaService).
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = "*", Condition = { StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" } } },
    ]
  })
}

resource "aws_codebuild_project" "smoke" {
  name          = "${var.name}-smoke"
  description   = "Playwright post-deploy functional smoke against staging (#…)."
  service_role  = aws_iam_role.smoke.arn
  build_timeout = 15

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "mcr.microsoft.com/playwright:v1.61.1-jammy" # node + browsers preinstalled; keep in lockstep with e2e/package.json
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "BASE_URL"
      value = var.staging_url
    }
    environment_variable {
      name  = "STATUS_URL"
      value = var.staging_status_url
    }
    environment_variable {
      name  = "CI"
      value = "1"
    }
    environment_variable {
      name  = "INTAKE_WEBHOOK_SECRET"
      value = var.staging_intake_secret_param
      type  = "PARAMETER_STORE"
    }
  }

  source {
    type = "CODEPIPELINE"
    buildspec = <<-YAML
      version: 0.2
      phases:
        build:
          commands:
            - cd e2e
            - npm install --no-audit --no-fund
            - npx playwright test --reporter=list
    YAML
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.smoke.name
    }
  }

  tags = var.tags
}

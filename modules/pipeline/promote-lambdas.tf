# Promote the escalation Lambdas — AFTER the app deploy, which means after migrations (platform#62).
#
# This used to happen in the BUILD stage: the buildspec called `aws lambda update-function-code`
# directly. Build therefore mutated the running estate, and on a fresh `make live` it deadlocked:
#
#   Build promotes new Lambda code  ->  new code meets the OLD schema (migrations have not run;
#   they run in CodeDeploy's BeforeAllowTraffic hook, one stage later)  ->  every Step Functions
#   execution fails (`column incidents_incident.number does not exist`)  ->  that trips the
#   watch-<env>-escalation-failed deploy-gate alarm  ->  CodeDeploy refuses to install  ->  THE
#   MIGRATIONS THAT WOULD HAVE FIXED IT NEVER RUN. Re-running does not help: the alarm is still on.
#
# So Build now only builds and publishes the zip. This promotes it, at run_order 3 in the deploy
# stage — behind the app (1) and the worker (2), i.e. behind the migration hook. Build produces,
# Deploy promotes, which is what build-once/promote-by-digest meant in the first place.

resource "aws_cloudwatch_log_group" "promote" {
  name              = "/codebuild/${var.name}-promote-lambdas"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_iam_role" "promote" {
  name                 = "${var.name}-promote"
  assume_role_policy   = data.aws_iam_policy_document.build_assume.json
  permissions_boundary = var.permissions_boundary != "" ? var.permissions_boundary : null
  tags                 = var.tags
}

resource "aws_iam_role_policy" "promote" {
  name = "${var.name}-promote"
  role = aws_iam_role.promote.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.promote.arn}:*" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = "${aws_s3_bucket.artifacts.arn}/*" },
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = aws_kms_key.artifacts.arn },
      {
        # Only this project's escalation functions (watch-<env>-{record-token,commit,intake-consumer}).
        # Not lambda:*, and not other projects' functions in a shared account.
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode", "lambda:PublishVersion", "lambda:GetFunction"]
        Resource = "arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${var.name}-*"
      },
    ]
  })
}

resource "aws_codebuild_project" "promote" {
  name          = "${var.name}-promote-lambdas"
  description   = "Promote the escalation Lambda zip built by Build — after migrations (platform#62)."
  service_role  = aws_iam_role.promote.arn
  build_timeout = 10

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "ARTIFACT_BUCKET"
      value = aws_s3_bucket.artifacts.bucket
    }
    environment_variable {
      # Overridden per action, so one project serves every env this pipeline deploys.
      name  = "LAMBDA_PREFIX"
      value = "unset"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.promote.name
    }
  }

  source {
    type = "CODEPIPELINE"
    # lambda-key.txt is written by the build: the S3 key of the zip it published. Promoting by KEY
    # (not by rebuilding) is what keeps this a promotion of the exact artifact that was tested.
    buildspec = <<-YAML
      version: 0.2
      phases:
        build:
          commands:
            - test -f lambda-key.txt || { echo "no lambda-key.txt in the build artifact"; exit 1; }
            - KEY=$(cat lambda-key.txt)
            - echo "Promoting $KEY to $LAMBDA_PREFIX"
            - |
              for fn in record-token commit intake-consumer; do
                aws lambda update-function-code --function-name "$${LAMBDA_PREFIX}-$${fn}" \
                  --s3-bucket "$ARTIFACT_BUCKET" --s3-key "$KEY" --publish >/dev/null \
                  && echo "  updated $${LAMBDA_PREFIX}-$${fn}"
              done
    YAML
  }

  tags = var.tags
}

# DAST stage (platform#32): OWASP ZAP baseline scan against the deployed STAGING app, run
# between DeployStaging and the prod approval — the runtime counterpart to the build-time
# SAST (Sonar) gate (ADR-004). Staging is prod-identical + disposable (ADR-019), so this is a
# safe, legitimate scan target. Staging is publicly reachable over HTTPS (watch-stg), so the
# scan needs no VPC. Reports land in the artifact bucket. Gating: ZAP runs with -I, so only
# alerts promoted to FAIL (via a tuned .zap rules config) block promotion — start
# non-breaking, tighten as false positives are triaged.

resource "aws_cloudwatch_log_group" "dast" {
  name              = "/codebuild/${var.name}-dast"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_iam_role" "dast" {
  name               = "${var.name}-dast"
  assume_role_policy = data.aws_iam_policy_document.build_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "dast" {
  name = "${var.name}-dast"
  role = aws_iam_role.dast.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.dast.arn}:*" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"], Resource = "${aws_s3_bucket.artifacts.arn}/*" },
    ]
  })
}

resource "aws_codebuild_project" "dast" {
  name          = "${var.name}-dast"
  description   = "OWASP ZAP baseline DAST against staging (#32)."
  service_role  = aws_iam_role.dast.arn
  build_timeout = 20

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # docker-in-docker to run the ZAP container

    environment_variable {
      name  = "TARGET_URL"
      value = var.staging_url
    }
    environment_variable {
      name  = "ARTIFACT_BUCKET"
      value = aws_s3_bucket.artifacts.bucket
    }
  }

  source {
    type = "CODEPIPELINE"
    buildspec = <<-YAML
      version: 0.2
      phases:
        build:
          commands:
            - echo "DAST (ZAP baseline) against $TARGET_URL"
            # The ZAP image runs as uid 1000 (user 'zap'); make the mounted work dir writable
            # by it so the report can be generated.
            - WRK="$(pwd)/zap-wrk"; mkdir -p "$WRK"; chmod 777 "$WRK"
            - |
              docker run --rm -v "$WRK:/zap/wrk:rw" ghcr.io/zaproxy/zaproxy:stable \
                zap-baseline.py -t "$TARGET_URL" -I -m 5 -r zap-report.html -w zap-report.md
              DAST_RC=$?
              echo "ZAP exit=$DAST_RC (0=pass, non-zero=FAIL-level alerts)"
            - TS=$(date +%Y%m%d-%H%M%S)
            - aws s3 cp "$WRK/zap-report.html" "s3://$ARTIFACT_BUCKET/dast/$TS-zap-report.html" || true
            - aws s3 cp "$WRK/zap-report.md"   "s3://$ARTIFACT_BUCKET/dast/$TS-zap-report.md"   || true
            - exit $${DAST_RC:-0}
    YAML
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.dast.name
    }
  }

  tags = var.tags
}

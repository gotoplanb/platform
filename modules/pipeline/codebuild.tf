# One CodeBuild: authoritative gates (make coverage; Sonar when configured) + build/push
# the image to the shared ECR ONCE, capture its digest, render per-env taskdef/appspec
# (image pinned by digest), and update both envs' Lambdas with one package.

resource "aws_cloudwatch_log_group" "build" {
  name              = "/codebuild/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "build_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "build" {
  name               = "${var.name}-build"
  assume_role_policy = data.aws_iam_policy_document.build_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "build" {
  name = "${var.name}-build"
  role = aws_iam_role.build.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.build.arn}:*" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"], Resource = "${aws_s3_bucket.artifacts.arn}/*" },
      # The artifact bucket is SSE-KMS (aws_kms_key.artifacts): decrypt to read the source artifact,
      # generate data keys to write build output. Latent until now — the old nonprod account's
      # CodeBuild 0-build hold meant Build never ran, so this was never exercised (see accounts.md).
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"], Resource = aws_kms_key.artifacts.arn },
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
        ]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.name}"
      },
      { Effect = "Allow", Action = ["ecs:DescribeTaskDefinition"], Resource = "*" },
      {
        # Promote the same Lambda package to both envs' functions.
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:PublishVersion"]
        Resource = "arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${var.name}-*"
      },
    ]
  })
}

resource "aws_codebuild_project" "this" {
  name          = var.name
  description   = "Watch gates + build-once (ADR-017): image by digest + per-env deploy artifacts."
  service_role  = aws_iam_role.build.arn
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "ECR_REPO_URL"
      value = var.ecr_repository_url
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
    environment_variable {
      name  = "CONTAINER_NAME"
      value = var.container_name
    }
    environment_variable {
      name  = "CONTAINER_PORT"
      value = tostring(var.container_port)
    }
    environment_variable {
      name  = "STAGING_TASK_FAMILY"
      value = var.staging.task_family
    }
    environment_variable {
      name  = "PROD_TASK_FAMILY"
      value = var.prod.task_family
    }
    environment_variable {
      name  = "STAGING_HOOK"
      value = aws_lambda_function.hook["staging"].function_name
    }
    environment_variable {
      name = "PROD_HOOK"
      # Prod's migration hook is deferred (cross-account, ADR-020) — empty so the buildspec renders
      # appspec-prod without a BeforeAllowTraffic hook; prod migrations run via db.sh for now.
      value = ""
    }
    environment_variable {
      name = "LAMBDA_ENVS"
      # Staging only. Prod's Lambdas live in the prod member account (prod-2, ADR-020), so the build
      # role (in nonprod) can't update-function-code them in-account — same cross-account boundary the
      # prod migration hook is deferred for (below). Promote prod Lambdas via lambda-promote.sh /
      # `make lambda-promote` (assumes cross-account). In-pipeline cross-account promotion is a follow-up.
      value = var.staging.task_family # function name prefix
    }
    environment_variable {
      name  = "ARTIFACT_BUCKET"
      value = aws_s3_bucket.artifacts.bucket
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build.name
    }
  }

  tags = var.tags
}

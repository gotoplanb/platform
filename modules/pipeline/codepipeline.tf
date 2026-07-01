# Source -> Build (once) -> DeployStaging -> manual approval -> DeployProd. Both deploy
# actions consume the SAME build artifact (per-env taskdef pinned to one image digest);
# there is NO CodeBuild in the prod path (ADR-017).

data "aws_iam_policy_document" "pipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${var.name}-pipeline"
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "pipeline" {
  name = "${var.name}-pipeline"
  role = aws_iam_role.pipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketLocation"], Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"] },
      { Effect = "Allow", Action = ["codestar-connections:UseConnection"], Resource = var.connection_arn },
      { Effect = "Allow", Action = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"], Resource = aws_codebuild_project.this.arn },
      {
        Effect = "Allow"
        Action = [
          "codedeploy:CreateDeployment", "codedeploy:GetDeployment", "codedeploy:GetDeploymentConfig",
          "codedeploy:RegisterApplicationRevision", "codedeploy:GetApplicationRevision",
          "codedeploy:GetApplication", "codedeploy:GetDeploymentGroup",
        ]
        Resource = "*"
      },
      { Effect = "Allow", Action = ["ecs:RegisterTaskDefinition", "ecs:DescribeServices", "ecs:DescribeTaskDefinition"], Resource = "*" },
      {
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = [var.staging.execution_role_arn, var.staging.task_role_arn, var.prod.execution_role_arn, var.prod.task_role_arn]
        Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_codepipeline" "this" {
  name          = var.name
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V2" # V2 required for the git push trigger below (#24)

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source"]
      configuration = {
        ConnectionArn    = var.connection_arn
        FullRepositoryId = var.github_repo_id
        BranchName       = var.github_branch
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source"]
      output_artifacts = ["build"]
      configuration    = { ProjectName = aws_codebuild_project.this.name }
    }
  }

  stage {
    name = "DeployStaging"
    action {
      name            = "DeployStaging"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeployToECS"
      version         = "1"
      input_artifacts = ["build"]
      configuration = {
        ApplicationName                = aws_codedeploy_app.this["staging"].name
        DeploymentGroupName            = aws_codedeploy_deployment_group.this["staging"].deployment_group_name
        TaskDefinitionTemplateArtifact = "build"
        TaskDefinitionTemplatePath     = "taskdef-staging.json"
        AppSpecTemplateArtifact        = "build"
        AppSpecTemplatePath            = "appspec-staging.yaml"
      }
    }
  }

  stage {
    name = "ApproveProd"
    action {
      name     = "ApproveProd"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
      configuration = {
        CustomData = "Promote the staging-verified digest to prod?"
      }
    }
  }

  stage {
    name = "DeployProd"
    action {
      name            = "DeployProd"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeployToECS"
      version         = "1"
      input_artifacts = ["build"]
      configuration = {
        ApplicationName                = aws_codedeploy_app.this["prod"].name
        DeploymentGroupName            = aws_codedeploy_deployment_group.this["prod"].deployment_group_name
        TaskDefinitionTemplateArtifact = "build"
        TaskDefinitionTemplatePath     = "taskdef-prod.json"
        AppSpecTemplateArtifact        = "build"
        AppSpecTemplatePath            = "appspec-prod.yaml"
      }
    }
  }

  # Auto-start on a push to the tracked branch via the CodeConnections webhook (#24), so a
  # merge to main runs build -> DeployStaging -> approval -> DeployProd without a manual start.
  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches {
          includes = [var.github_branch]
        }
      }
    }
  }

  tags = var.tags
}

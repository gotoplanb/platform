# App stack (platform#6): ECR + ECS Fargate service behind an ALB with blue/green target
# groups, an AppConfig Agent sidecar, secrets via the task-def `secrets` block (never
# inlined, §4.3), and subnet placement that follows the cost profile (ADR-015). Composes
# the network (#3), data (#4), and config (#5) stacks. CodeDeploy (#10) owns deployments;
# this stack ignores the attributes CodeDeploy mutates.

data "aws_caller_identity" "current" {}

locals {
  image = var.image_uri != "" ? var.image_uri : "${aws_ecr_repository.app.repository_url}:bootstrap"

  # ha → private subnets, no public IP (egress via NAT); lean → public subnets + public IP.
  service_subnets  = var.private_networking ? var.private_subnet_ids : var.public_subnet_ids
  assign_public_ip = !var.private_networking
  otel_enabled     = var.otel_exporter_endpoint != ""
  container_name   = "app"
  app_port         = 8000
  appconfig_port   = 2772

  # Non-secret container env (the app reads these; secrets come via the `secrets` block).
  app_environment = [
    { name = "POSTGRES_HOST", value = var.db_address },
    { name = "POSTGRES_PORT", value = tostring(var.db_port) },
    { name = "POSTGRES_DB", value = var.db_name },
    { name = "POSTGRES_USER", value = var.db_username },
    { name = "VALKEY_URL", value = var.valkey_url },
    { name = "FLAGS_PROVIDER", value = "appconfig" },
    { name = "APPCONFIG_AGENT_URL", value = "http://localhost:${local.appconfig_port}" },
    { name = "APPCONFIG_APPLICATION", value = var.appconfig_application_name },
    { name = "APPCONFIG_ENVIRONMENT", value = var.appconfig_environment_name },
    { name = "APPCONFIG_PROFILE", value = var.appconfig_profile_name },
    { name = "AWS_REGION", value = var.region },
    # ALB-only ingress (SG) is the trust boundary; #13 tightens this to the real domain.
    { name = "DJANGO_ALLOWED_HOSTS", value = "*" },
    { name = "OTEL_ENABLED", value = local.otel_enabled ? "1" : "0" },
    { name = "OTEL_SERVICE_NAME", value = "watch-backend" },
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = var.otel_exporter_endpoint },
  ]

  # Secrets resolved at launch by the execution role (SSM SecureStrings + the RDS-managed
  # Secrets Manager credential). Values never appear in the task def or logs.
  app_secrets = [
    { name = "DJANGO_SECRET_KEY", valueFrom = var.django_secret_key_param_arn },
    { name = "INTAKE_WEBHOOK_SECRET", valueFrom = var.intake_webhook_secret_param_arn },
    { name = "POSTGRES_PASSWORD", valueFrom = "${var.db_master_secret_arn}:password::" },
  ]

  container_definitions = [
    {
      name      = local.container_name
      image     = local.image
      essential = true
      portMappings = [
        { containerPort = local.app_port, protocol = "tcp" }
      ]
      environment = local.app_environment
      secrets     = local.app_secrets
      dependsOn = [
        { containerName = "appconfig-agent", condition = "START" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "app"
        }
      }
    },
    {
      # AppConfig Agent sidecar (ADR-003): same localhost:2772 path the app uses locally.
      # Uses the task role for AWS creds; fetches the flag profile on demand.
      name      = "appconfig-agent"
      image     = var.appconfig_agent_image
      essential = true
      environment = [
        { name = "SERVICE_REGION", value = var.region }
      ]
      portMappings = [
        { containerPort = local.appconfig_port, protocol = "tcp" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "appconfig-agent"
        }
      }
    },
  ]
}

resource "aws_ecr_repository" "app" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true # ephemeral test loop; real prod would keep images

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.tags, { Name = var.name })
}

# Keep ECR tidy: expire untagged images.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = merge(var.tags, { Name = var.name })
}

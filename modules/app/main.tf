# App stack (platform#6): ECR + ECS Fargate service behind an ALB with blue/green target
# groups, an AppConfig Agent sidecar, secrets via the task-def `secrets` block (never
# inlined, §4.3), and subnet placement that follows the cost profile (ADR-015). Composes
# the network (#3), data (#4), and config (#5) stacks. CodeDeploy (#10) owns deployments;
# this stack ignores the attributes CodeDeploy mutates.

data "aws_caller_identity" "current" {}

locals {
  image = var.image_uri != "" ? var.image_uri : "${var.image_repository_url}:bootstrap"

  # ha → private subnets, no public IP (egress via NAT); lean → public subnets + public IP.
  service_subnets  = var.private_networking ? var.private_subnet_ids : var.public_subnet_ids
  assign_public_ip = !var.private_networking
  container_name   = "app"
  app_port         = 8000
  appconfig_port   = 2772
  otel_grpc_port   = 4317
  otel_http_port   = 4318

  # Alloy sidecar config (ADR-016 / #18): receive OTLP from the app on localhost, batch, and
  # forward to the per-env gateway (#19) — or a debug sink when no gateway is wired yet, so the
  # app→sidecar path is verifiable. Tail-sampling + redaction + vendor creds live at the
  # gateway (ADR-016 §3), never in the per-task sidecar.
  alloy_exporter_ref = var.telemetry_gateway_endpoint != "" ? "otelcol.exporter.otlp.gateway.input" : "otelcol.exporter.debug.sink.input"
  alloy_exporter_block = var.telemetry_gateway_endpoint != "" ? (
    "otelcol.exporter.otlp \"gateway\" {\n  client {\n    endpoint = \"${var.telemetry_gateway_endpoint}\"\n    tls { insecure = true }\n  }\n}"
    ) : (
    "otelcol.exporter.debug \"sink\" {\n  verbosity = \"basic\"\n}"
  )
  alloy_config = <<-EOT
    otelcol.receiver.otlp "in" {
      grpc { endpoint = "0.0.0.0:${local.otel_grpc_port}" }
      http { endpoint = "0.0.0.0:${local.otel_http_port}" }
      output {
        traces  = [otelcol.processor.batch.b.input]
        metrics = [otelcol.processor.batch.b.input]
        logs    = [otelcol.processor.batch.b.input]
      }
    }
    otelcol.processor.batch "b" {
      output {
        traces  = [${local.alloy_exporter_ref}]
        metrics = [${local.alloy_exporter_ref}]
        logs    = [${local.alloy_exporter_ref}]
      }
    }
    ${local.alloy_exporter_block}
  EOT

  # The escalation state machine (#7) is named var.name; predict its ARN so the app can
  # StartExecution / SendTaskSuccess without a circular dependency on the escalation stack.
  escalation_state_machine_arn = "arn:aws:states:${var.region}:${data.aws_caller_identity.current.account_id}:stateMachine:${var.name}"

  # Non-secret container env (the app reads these; secrets come via the `secrets` block).
  app_environment = concat([
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
    { name = "ESCALATION_STATE_MACHINE_ARN", value = local.escalation_state_machine_arn },
    { name = "ESCALATION_LOCAL_MODE", value = "0" }, # real Step Functions engine (default is local)
    # ALB-only ingress (SG) is the trust boundary; #13 tightens this to the real domain.
    { name = "DJANGO_ALLOWED_HOSTS", value = "*" },
    # Backend-agnostic (ADR-016): always export OTLP to the local Alloy sidecar — never a
    # remote/vendor endpoint. Resource attrs (env + version) are the only per-deploy telemetry
    # identity the app carries; the SDK merges OTEL_RESOURCE_ATTRIBUTES into the resource.
    { name = "OTEL_ENABLED", value = "1" },
    { name = "OTEL_SERVICE_NAME", value = "watch-backend" },
    { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:${local.otel_http_port}" },
    { name = "OTEL_RESOURCE_ATTRIBUTES", value = "deployment.environment=${var.env},service.version=${var.service_version}" },
    ], var.app_hostname != "" ? [
    # HTTPS (#13): trust the public origin for CSRF + secure cookies behind the ALB.
    { name = "CSRF_TRUSTED_ORIGINS", value = "https://${var.app_hostname}" },
    { name = "SESSION_COOKIE_SECURE", value = "1" },
    { name = "CSRF_COOKIE_SECURE", value = "1" },
  ] : [])

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
    {
      # Alloy telemetry sidecar (ADR-016 / #18): receives the app's OTLP on localhost
      # :4317/:4318 and forwards to the per-env gateway. essential=false — telemetry down must
      # never take the app down (the app buffers; egress stays off the critical path). Config
      # is delivered via env→file so no custom image is needed (#19 may move it to SSM/S3).
      name       = "alloy"
      image      = var.alloy_image
      essential  = false
      # --stability.level=experimental enables otelcol.exporter.debug (the no-gateway sink);
      # the GA otlp exporter used once a gateway is wired doesn't need it, but the flag is safe.
      entryPoint = ["sh", "-c", "printf '%s' \"$ALLOY_CONFIG\" > /tmp/config.alloy && exec alloy run /tmp/config.alloy --server.http.listen-addr=0.0.0.0:12345 --storage.path=/tmp/alloy --stability.level=experimental"]
      environment = [
        { name = "ALLOY_CONFIG", value = local.alloy_config }
      ]
      portMappings = [
        { containerPort = local.otel_grpc_port, protocol = "tcp" },
        { containerPort = local.otel_http_port, protocol = "tcp" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "alloy"
        }
      }
    },
  ]
}

# ECR is now the shared region-level repo (platform#20); both envs pull the same digest.
# The app stack consumes it via var.image_repository_url (was a per-env repo created here).

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = merge(var.tags, { Name = var.name })
}

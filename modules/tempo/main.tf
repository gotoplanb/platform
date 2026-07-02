# Durable trace backend for the observability plane (platform#29, ADR-018). Grafana Tempo on
# Fargate: its distributor accepts OTLP directly (:4317/:4318) from the per-env gateway, stores
# traces locally (a warm-minimal staging backend — no S3/EFS), and serves the query API on :3200
# for Grafana. Co-located in the staging VPC (both staging and the slice are warm-standby now, so
# no VPC peering); reachable via Cloud Map at tempo.<namespace>. This module also owns the shared
# obs ECS cluster + Cloud Map namespace, which the Grafana stack reuses.
#
# Rewritten from the ~/watchtower terragrunt draft (never applied) to align with platform: no
# Service Connect / baked image / S3 — config is delivered env->file like the Alloy sidecar, and
# the gateway talks straight to Tempo's OTLP receiver instead of a second Alloy hop.

locals {
  api_port  = 3200
  grpc_port = 4317
  http_port = 4318

  service_subnets  = var.private_networking ? var.private_subnet_ids : var.public_subnet_ids
  assign_public_ip = !var.private_networking

  tempo_config = <<-EOT
    server:
      http_listen_port: ${local.api_port}
    distributor:
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: "0.0.0.0:${local.grpc_port}"
            http:
              endpoint: "0.0.0.0:${local.http_port}"
    ingester:
      max_block_duration: 5m
    compactor:
      compaction:
        block_retention: ${var.trace_retention}
    storage:
      trace:
        backend: local
        wal:
          path: /tmp/tempo/wal
        local:
          path: /tmp/tempo/blocks
    usage_report:
      reporting_enabled: false
  EOT
}

# --- shared obs foundation (Grafana reuses these) ---
resource "aws_ecs_cluster" "this" {
  name = "${var.name}-obs"
  tags = var.tags
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name = var.namespace
  vpc  = var.vpc_id
  tags = var.tags
}

resource "aws_service_discovery_service" "tempo" {
  name = "tempo"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 15
    }
  }
  # No health_check_custom_config — empty block reads back absent (perpetual ForceNew diff).
  tags = var.tags
}

# --- network ---
resource "aws_security_group" "tempo" {
  name        = "${var.name}-tempo"
  description = "Tempo - OTLP from the gateway, query API from Grafana"
  vpc_id      = var.vpc_id

  ingress {
    description     = "OTLP gRPC from the telemetry gateway"
    from_port       = local.grpc_port
    to_port         = local.grpc_port
    protocol        = "tcp"
    security_groups = [var.gateway_sg_id]
  }
  ingress {
    description     = "OTLP HTTP from the telemetry gateway"
    from_port       = local.http_port
    to_port         = local.http_port
    protocol        = "tcp"
    security_groups = [var.gateway_sg_id]
  }
  # Query API (:3200) ingress from Grafana is added by the grafana stack as a standalone rule
  # (grafana's SG doesn't exist yet here — adding it there avoids a dependency cycle).
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = var.tags
}

# --- roles ---
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-tempo-exec"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "task" {
  name               = "${var.name}-tempo-task"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_cloudwatch_log_group" "tempo" {
  name              = "/ecs/${var.name}-tempo"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_task_definition" "tempo" {
  family                   = "${var.name}-tempo"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name       = "tempo"
      image      = var.tempo_image
      essential  = true
      entryPoint = ["sh", "-c", "printf '%s' \"$TEMPO_CONFIG\" > /tmp/tempo.yaml && exec /tempo -config.file=/tmp/tempo.yaml"]
      environment = [
        { name = "TEMPO_CONFIG", value = local.tempo_config }
      ]
      portMappings = [
        { containerPort = local.api_port, protocol = "tcp" },
        { containerPort = local.grpc_port, protocol = "tcp" },
        { containerPort = local.http_port, protocol = "tcp" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.tempo.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "tempo"
        }
      }
    }
  ])
  tags = var.tags
}

resource "aws_ecs_service" "tempo" {
  name            = "${var.name}-tempo"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.tempo.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.service_subnets
    security_groups  = [aws_security_group.tempo.id]
    assign_public_ip = local.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.tempo.arn
  }

  lifecycle {
    ignore_changes = [desired_count] # warm-minimal scaling operated out of band
  }
  tags = var.tags
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}
output "namespace_id" {
  value = aws_service_discovery_private_dns_namespace.this.id
}
output "namespace_name" {
  value = aws_service_discovery_private_dns_namespace.this.name
}
output "otlp_endpoint" {
  description = "gRPC endpoint the gateway forwards traces to."
  value       = "tempo.${aws_service_discovery_private_dns_namespace.this.name}:${local.grpc_port}"
}
output "query_endpoint" {
  description = "HTTP query API for Grafana's Tempo datasource."
  value       = "http://tempo.${aws_service_discovery_private_dns_namespace.this.name}:${local.api_port}"
}
output "security_group_id" {
  value = aws_security_group.tempo.id
}
output "api_port" {
  value = local.api_port
}

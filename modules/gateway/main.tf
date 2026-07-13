# Per-env Alloy telemetry gateway (platform#19, ADR-016). A shared Alloy collector the app
# tasks' sidecars forward to: it batches, (optionally) tail-samples traces, and exports to the
# env's destination (the Watchtower slice / a vendor / a debug sink until one is wired). Runs as
# an ECS Fargate service in the private subnets, discoverable via Cloud Map so the sidecars reach
# it at gateway.<namespace>:4317. Tail-sampling needs to see whole traces, which a per-task
# sidecar can't — this is why the gateway exists.

data "aws_caller_identity" "current" {}

locals {
  grpc_port       = 4317
  http_port       = 4318
  admin_port      = 12345
  vendor_auth_env = "VENDOR_OTLP_AUTH"
  # nonsensitive: whether a header is *set* isn't secret (only its value is); without this the
  # sensitivity propagates into container_definitions and forces a spurious task-def re-render.
  has_vendor_auth = nonsensitive(var.vendor_auth_header != "")

  # Follow the app's cost profile (ADR-015): lean → public subnets + public IP (no NAT);
  # ha → private subnets, egress via NAT. A private task with no public IP + no NAT can't
  # pull its image, so this has to match the env.
  service_subnets  = var.private_networking ? var.private_subnet_ids : var.public_subnet_ids
  assign_public_ip = !var.private_networking
}

module "config" {
  source                 = "../alloy"
  role                   = "gateway"
  grpc_port              = local.grpc_port
  http_port              = local.http_port
  forward_endpoint       = var.forward_endpoint
  vendor_endpoint        = var.vendor_endpoint
  vendor_auth_header_env = local.vendor_auth_env
  tail_sampling          = var.tail_sampling
  sampling_percentage    = var.sampling_percentage
  dest_traces_only       = var.dest_traces_only
}

# Vendor Authorization header as a TF-managed SecureString (created from a sensitive var,
# mirroring the secrets-appconfig SSM pattern — value from a var instead of random_password since
# it's externally issued). The gateway task reads it at launch via the secrets block.
resource "aws_ssm_parameter" "vendor_auth" {
  count = local.has_vendor_auth ? 1 : 0
  name  = "/${var.name}/telemetry/vendor-auth-header"
  type  = "SecureString"
  value = var.vendor_auth_header
  tags  = var.tags
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name}-gateway"
  tags = var.tags
}

# --- discovery: sidecars resolve gateway.<namespace> ---
resource "aws_service_discovery_private_dns_namespace" "this" {
  name = "${var.name}.svc"
  vpc  = var.vpc_id
  tags = var.tags
}

resource "aws_service_discovery_service" "gateway" {
  name = "gateway"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 15
    }
  }
  # No health_check_custom_config: an empty block reads back as absent (perpetual ForceNew diff),
  # and MULTIVALUE routing doesn't need one.
  tags = var.tags
}

# --- network: the app SG may reach the gateway on the OTLP ports ---
resource "aws_security_group" "gateway" {
  name        = "${var.name}-gateway"
  description = "Alloy gateway - OTLP from the app sidecars"
  vpc_id      = var.vpc_id

  ingress {
    description     = "OTLP gRPC from app tasks"
    from_port       = local.grpc_port
    to_port         = local.grpc_port
    protocol        = "tcp"
    security_groups = [var.app_sg_id]
  }
  ingress {
    description     = "OTLP HTTP from app tasks"
    from_port       = local.http_port
    to_port         = local.http_port
    protocol        = "tcp"
    security_groups = [var.app_sg_id]
  }
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
  name                 = "${var.name}-gateway-exec"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary != "" ? var.permissions_boundary : null
  tags                 = var.tags
}
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "task" {
  name                 = "${var.name}-gateway-task"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary != "" ? var.permissions_boundary : null
  tags                 = var.tags
}

# Execution role reads the vendor auth header (SecureString) at launch.
data "aws_iam_policy_document" "read_token" {
  count = local.has_vendor_auth ? 1 : 0
  statement {
    actions   = ["ssm:GetParameters"]
    resources = [aws_ssm_parameter.vendor_auth[0].arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}
resource "aws_iam_role_policy" "read_token" {
  count  = local.has_vendor_auth ? 1 : 0
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_token[0].json
}

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/ecs/${var.name}-gateway"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_task_definition" "gateway" {
  family                   = "${var.name}-gateway"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "alloy"
      image     = var.alloy_image
      essential = true
      # Config via env→file (no custom image); experimental flag for the debug sink / tail-sampling.
      entryPoint = ["sh", "-c", "printf '%s' \"$ALLOY_CONFIG\" > /tmp/config.alloy && exec alloy run /tmp/config.alloy --server.http.listen-addr=0.0.0.0:${local.admin_port} --storage.path=/tmp/alloy --stability.level=experimental"]
      environment = [
        { name = "ALLOY_CONFIG", value = module.config.config }
      ]
      # Vendor token (Grafana Cloud) resolved at launch by the execution role — never inlined.
      secrets = local.has_vendor_auth ? [
        { name = local.vendor_auth_env, valueFrom = aws_ssm_parameter.vendor_auth[0].arn }
      ] : []
      portMappings = [
        { containerPort = local.grpc_port, protocol = "tcp" },
        { containerPort = local.http_port, protocol = "tcp" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.gateway.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "gateway"
        }
      }
    }
  ])
  tags = var.tags
}

resource "aws_ecs_service" "gateway" {
  name            = "${var.name}-gateway"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.gateway.arn
  desired_count   = var.desired_count # 0 = warm-minimal idle (scale up when needed)
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.service_subnets
    security_groups  = [aws_security_group.gateway.id]
    assign_public_ip = local.assign_public_ip
  }

  service_registries {
    registry_arn = aws_service_discovery_service.gateway.arn
  }

  lifecycle {
    ignore_changes = [desired_count] # warm-minimal scaling is operated out of band
  }
  tags = var.tags
}

output "endpoint" {
  description = "gRPC endpoint the app sidecars forward OTLP to."
  value       = "gateway.${aws_service_discovery_private_dns_namespace.this.name}:${local.grpc_port}"
}

output "security_group_id" {
  description = "The gateway tasks' SG — the telemetry backend allows this on its OTLP ingress."
  value       = aws_security_group.gateway.id
}

# Grafana viewer for the observability plane (platform#29, ADR-018). Fargate Grafana behind a
# small public ALB, with the Tempo datasource provisioned so traces are viewable out of the box.
# Reuses the obs ECS cluster + Cloud Map namespace created by modules/tempo. Warm-minimal: no EFS
# (dashboards/datasource are provisioned config, not user state), admin password from SSM.
# Rewritten from the ~/watchtower draft to align with platform (env->file provisioning, no baked
# image, no EFS).

locals {
  grafana_port = 3000

  service_subnets  = var.private_networking ? var.private_subnet_ids : var.public_subnet_ids
  assign_public_ip = !var.private_networking

  tempo_datasource = <<-EOT
    apiVersion: 1
    datasources:
      - name: Tempo
        type: tempo
        access: proxy
        url: ${var.tempo_query_endpoint}
        isDefault: true
        editable: false
  EOT
}

# --- admin password (generated, stored in SSM; never inlined) ---
resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "admin" {
  name  = "/${var.name}/grafana/admin-password"
  type  = "SecureString"
  value = random_password.admin.result
  tags  = var.tags
}

# --- security groups ---
resource "aws_security_group" "alb" {
  name        = "${var.name}-grafana-alb"
  description = "Grafana ALB - public HTTP"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from anywhere (staging viewer)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = var.tags
}

resource "aws_security_group" "grafana" {
  name        = "${var.name}-grafana"
  description = "Grafana task - from the ALB"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Grafana UI from the ALB"
    from_port       = local.grafana_port
    to_port         = local.grafana_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = var.tags
}

# Grafana -> Tempo query API (:3200). Added here (not in modules/tempo) to avoid a dependency
# cycle: this SG doesn't exist when Tempo is planned.
resource "aws_security_group_rule" "grafana_to_tempo" {
  type                     = "ingress"
  description              = "Grafana query API"
  from_port                = var.tempo_api_port
  to_port                  = var.tempo_api_port
  protocol                 = "tcp"
  security_group_id        = var.tempo_sg_id
  source_security_group_id = aws_security_group.grafana.id
}

# --- ALB ---
resource "aws_lb" "grafana" {
  name               = "${var.name}-grafana"
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]
  tags               = var.tags
}

resource "aws_lb_target_group" "grafana" {
  name        = "${var.name}-grafana"
  port        = local.grafana_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/api/health"
    healthy_threshold   = 2
    unhealthy_threshold = 5
    interval            = 30
    matcher             = "200"
  }
  tags = var.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.grafana.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
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
  name                 = "${var.name}-grafana-exec"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary != "" ? var.permissions_boundary : null
  tags                 = var.tags
}
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Execution role reads the admin-password SecureString at launch.
data "aws_iam_policy_document" "read_secret" {
  statement {
    actions   = ["ssm:GetParameters"]
    resources = [aws_ssm_parameter.admin.arn]
  }
}
resource "aws_iam_role_policy" "read_secret" {
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_secret.json
}

resource "aws_iam_role" "task" {
  name                 = "${var.name}-grafana-task"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary != "" ? var.permissions_boundary : null
  tags                 = var.tags
}

resource "aws_cloudwatch_log_group" "grafana" {
  name              = "/ecs/${var.name}-grafana"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_task_definition" "grafana" {
  family                   = "${var.name}-grafana"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name       = "grafana"
      image      = var.grafana_image
      essential  = true
      entryPoint = ["sh", "-c", "mkdir -p /tmp/gf/datasources && printf '%s' \"$TEMPO_DATASOURCE\" > /tmp/gf/datasources/tempo.yaml && exec /run.sh"]
      environment = [
        { name = "GF_PATHS_PROVISIONING", value = "/tmp/gf" },
        { name = "GF_SECURITY_ADMIN_USER", value = "admin" },
        { name = "GF_USERS_ALLOW_SIGN_UP", value = "false" },
        { name = "TEMPO_DATASOURCE", value = local.tempo_datasource },
      ]
      secrets = [
        { name = "GF_SECURITY_ADMIN_PASSWORD", valueFrom = aws_ssm_parameter.admin.arn }
      ]
      portMappings = [
        { containerPort = local.grafana_port, protocol = "tcp" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.grafana.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "grafana"
        }
      }
    }
  ])
  tags = var.tags
}

resource "aws_ecs_service" "grafana" {
  name            = "${var.name}-grafana"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.service_subnets
    security_groups  = [aws_security_group.grafana.id]
    assign_public_ip = local.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.grafana.arn
    container_name   = "grafana"
    container_port   = local.grafana_port
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
  depends_on = [aws_lb_listener.http]
  tags       = var.tags
}

output "url" {
  value = "http://${aws_lb.grafana.dns_name}"
}
output "admin_password_param" {
  value = aws_ssm_parameter.admin.name
}

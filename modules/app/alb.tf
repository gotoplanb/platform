# ALB for blue/green (issue #6 / ADR-004): two IP target groups + a production listener
# (:80) and a test listener (:8080). CodeDeploy (#10) shifts traffic by swapping which
# target group each listener forwards to, so Terraform ignores listener default_action.
# HTTPS (:443 + ACM) is added in #13; until then the production listener is HTTP.

resource "aws_lb" "this" {
  name               = var.name
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [var.alb_sg_id]

  # Public-facing; in lean the app shares these subnets, in ha only the ALB does.
  internal = false

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_lb_target_group" "blue" {
  name        = "${var.name}-blue"
  port        = local.app_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/api/health"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }

  tags = merge(var.tags, { Name = "${var.name}-blue" })
}

resource "aws_lb_target_group" "green" {
  name        = "${var.name}-green"
  port        = local.app_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/api/health"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }

  tags = merge(var.tags, { Name = "${var.name}-green" })
}

resource "aws_lb_listener" "production" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  # CodeDeploy swaps the forward target during blue/green deploys.
  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.this.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

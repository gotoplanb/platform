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

# Non-HTTPS envs: :80 is the CodeDeploy production listener (forward, swapped).
resource "aws_lb_listener" "production" {
  count             = var.app_hostname == "" ? 1 : 0
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

# HTTPS envs: :443 is production (above); :80 just redirects to it (HTTPS-only, #13).
resource "aws_lb_listener" "http_redirect" {
  count             = var.app_hostname != "" ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
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

# HTTPS production listener (#13). When app_hostname is set, find its ACM cert (the DNS
# stack created it) and serve :443. The pipeline repoints CodeDeploy's prod route here, so
# blue/green swaps :443. (:80 redirect → :443 is a follow-up.)
data "aws_acm_certificate" "app" {
  count       = var.app_hostname != "" ? 1 : 0
  domain      = var.app_hostname
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "aws_lb_listener" "https" {
  count             = var.app_hostname != "" ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.app[0].arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  lifecycle {
    ignore_changes = [default_action] # CodeDeploy swaps the forward target
  }
}

# Observability stack (platform#11, §4.8). Two concrete pieces:
#   - CloudWatch alarms (ALB 5xx — LB-generated and target/app) that the blue/green deploy
#     gate references for auto-rollback (#10), alongside the escalation alarm (#7).
#   - "Masked drains": a CloudWatch Logs data-protection policy on the app log group as the
#     sink-level floor — managed data identifiers (email, IP) are masked even if something
#     slips past app-layer redaction (which stays authoritative).
#
# OTLP -> Watchtower: the app's OTEL_EXPORTER_OTLP_ENDPOINT (#6 seam) is the hook. Reaching
# the *local* Watchtower from AWS is an open decision (expose its OTLP via a tunnel, or run
# an in-VPC ADOT/Alloy collector that forwards) — see the issue; not wired here yet.

locals {
  # CloudWatch ALB metric dimension = the ARN segment after "loadbalancer/".
  alb_suffix    = element(split("loadbalancer/", var.alb_arn), 1)
  app_log_group = "/ecs/${var.name}"
}

resource "aws_cloudwatch_metric_alarm" "elb_5xx" {
  alarm_name          = "${var.name}-alb-5xx"
  alarm_description   = "ALB-generated 5xx (the load balancer itself failing requests)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.alb_5xx_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { LoadBalancer = local.alb_suffix }
  tags       = var.tags
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.name}-target-5xx"
  alarm_description   = "App-returned 5xx behind the ALB."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.alb_5xx_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { LoadBalancer = local.alb_suffix }
  tags       = var.tags
}

# Sink-level redaction floor for the app log group (created by #6).
resource "aws_cloudwatch_log_data_protection_policy" "app" {
  log_group_name = local.app_log_group

  policy_document = jsonencode({
    Name    = "${var.name}-mask"
    Version = "2021-06-01"
    Statement = [
      {
        Sid            = "audit"
        DataIdentifier = var.masked_data_identifiers
        Operation      = { Audit = { FindingsDestination = {} } }
      },
      {
        Sid            = "deidentify"
        DataIdentifier = var.masked_data_identifiers
        Operation      = { Deidentify = { MaskConfig = {} } }
      },
    ]
  })
}

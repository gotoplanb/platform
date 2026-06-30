# Per-env CodeDeploy ECS blue/green (staging + prod). Same shape as before, now one app +
# deployment group per env, alarm-gated with auto-rollback.

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${var.name}-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "deploy_ecs" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

resource "aws_codedeploy_app" "this" {
  for_each         = local.envs
  name             = "${var.name}-${each.key}"
  compute_platform = "ECS"
  tags             = var.tags
}

resource "aws_codedeploy_deployment_group" "this" {
  for_each               = local.envs
  app_name               = aws_codedeploy_app.this[each.key].name
  deployment_group_name  = "${var.name}-${each.key}"
  service_role_arn       = aws_iam_role.deploy.arn
  deployment_config_name = var.deploy_config_name

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  ecs_service {
    cluster_name = each.value.cluster_name
    service_name = each.value.service_name
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [each.value.production_listener_arn]
      }
      test_traffic_route {
        listener_arns = [each.value.test_listener_arn]
      }
      target_group {
        name = each.value.blue_target_group_name
      }
      target_group {
        name = each.value.green_target_group_name
      }
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  dynamic "alarm_configuration" {
    for_each = length(each.value.rollback_alarm_names) > 0 ? [1] : []
    content {
      enabled = true
      alarms  = each.value.rollback_alarm_names
    }
  }

  tags = var.tags
}

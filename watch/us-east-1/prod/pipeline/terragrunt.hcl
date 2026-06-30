# Pipeline stack for watch / prod / us-east-1 (platform#10). CodeConnections -> CodeBuild
# (coverage gate + image) -> CodeDeploy ECS blue/green into the app stack (#6). Auto-rollback
# is gated on the escalation alarm (#7). The first run needs the CodeConnections handshake
# authorized (one-time, manual) and buildspec.yml on the watch repo's main branch.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env  = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
  name = "${local.env.project}-${local.env.env}"
}

dependency "app" {
  config_path = "../app"
  mock_outputs = {
    ecr_repository_url      = "000000000000.dkr.ecr.us-east-1.amazonaws.com/watch-prod"
    cluster_name            = "watch-prod"
    service_name            = "watch-prod"
    blue_target_group_name  = "watch-prod-blue"
    green_target_group_name = "watch-prod-green"
    production_listener_arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/app/watch-prod/x/y"
    test_listener_arn       = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/app/watch-prod/x/z"
    execution_role_arn      = "arn:aws:iam::000000000000:role/watch-prod-exec"
    task_role_arn           = "arn:aws:iam::000000000000:role/watch-prod-task"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Deploy-gate alarms must exist before CodeDeploy creates the deployment group, so depend
# on the stacks that own them (#7 escalation, #11 observability) for both ordering + names.
dependency "escalation" {
  config_path                             = "../escalation"
  mock_outputs                            = { executions_failed_alarm_name = "watch-prod-escalation-failed" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "observability" {
  config_path                             = "../observability"
  mock_outputs                            = { alarm_names = ["watch-prod-alb-5xx", "watch-prod-target-5xx"] }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}//modules/pipeline"
}

inputs = {
  name   = local.name
  env    = local.env.env
  region = local.env.region

  github_repo_id = "gotoplanb/watch"
  github_branch  = "main"

  ecr_repository_url = dependency.app.outputs.ecr_repository_url
  ecs_cluster_name   = dependency.app.outputs.cluster_name
  ecs_service_name   = dependency.app.outputs.service_name
  ecs_task_family    = local.name

  production_listener_arn = dependency.app.outputs.production_listener_arn
  test_listener_arn       = dependency.app.outputs.test_listener_arn
  blue_target_group_name  = dependency.app.outputs.blue_target_group_name
  green_target_group_name = dependency.app.outputs.green_target_group_name

  execution_role_arn = dependency.app.outputs.execution_role_arn
  task_role_arn      = dependency.app.outputs.task_role_arn

  # Auto-rollback on escalation (#7) or ALB 5xx (#11). Sourced from those stacks' outputs so
  # the deployment group is created only after the alarms exist (CodeDeploy validates them).
  rollback_alarm_names = concat(
    [dependency.escalation.outputs.executions_failed_alarm_name],
    dependency.observability.outputs.alarm_names,
  )

  tags = { env = local.env.env }
}

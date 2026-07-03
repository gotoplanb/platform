# Prod deploy plane in watch-prod (platform#22, ADR-020): the prod ECS blue/green CodeDeploy +
# the cross-account role the nonprod pipeline's DeployProd action assumes. Routes to watch-prod
# (root seam, path prod/). Depends on prod/app (the ECS service + ALB TGs/listeners + roles) and
# the pipeline (the artifact bucket + KMS ARNs to grant read/decrypt — the KMS ARN isn't
# predictable). CodeDeploy app/DG + role are named watch-prod / watch-prod-deploy so the pipeline
# references them without a reverse dependency.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "app" {
  config_path = "../app"
  mock_outputs = {
    cluster_name            = "watch-prod"
    service_name            = "watch-prod"
    https_listener_arn      = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/app/watch-prod/x/h"
    test_listener_arn       = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/app/watch-prod/x/z"
    blue_target_group_name  = "watch-prod-blue"
    green_target_group_name = "watch-prod-green"
    execution_role_arn      = "arn:aws:iam::000000000000:role/watch-prod-exec"
    task_role_arn           = "arn:aws:iam::000000000000:role/watch-prod-task"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "pipeline" {
  config_path = "../../pipeline"
  mock_outputs = {
    artifact_bucket_arn  = "arn:aws:s3:::watch-pipeline-000000000000"
    artifact_kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

terraform {
  source = "${get_repo_root()}//modules/prod-deploy"
}

inputs = {
  name               = "${local.env.project}-${local.env.env}" # watch-prod
  trusted_account_id = get_env("WATCH_NONPROD_ACCOUNT_ID", "")  # the nonprod pipeline account

  artifact_bucket_arn  = dependency.pipeline.outputs.artifact_bucket_arn
  artifact_kms_key_arn = dependency.pipeline.outputs.artifact_kms_key_arn

  cluster_name            = dependency.app.outputs.cluster_name
  service_name            = dependency.app.outputs.service_name
  production_listener_arn = dependency.app.outputs.https_listener_arn # :443 (#13)
  test_listener_arn       = dependency.app.outputs.test_listener_arn
  blue_target_group_name  = dependency.app.outputs.blue_target_group_name
  green_target_group_name = dependency.app.outputs.green_target_group_name
  execution_role_arn      = dependency.app.outputs.execution_role_arn
  task_role_arn           = dependency.app.outputs.task_role_arn
  rollback_alarm_names    = ["watch-prod-escalation-failed", "watch-prod-alb-5xx", "watch-prod-target-5xx"]
}

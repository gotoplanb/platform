# Region-level pipeline (platform#20). Spans both envs: build once -> deploy staging ->
# approve -> deploy prod, promoting one image digest. Supersedes watch/us-east-1/prod/pipeline.
# Prereqs to apply: the shared ECR (../ecr) and the staging env (../staging/*) must exist.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  region = "us-east-1"
  acct   = read_terragrunt_config(find_in_parent_folders("accounts.hcl")).locals
}

dependency "ecr" {
  config_path                             = "../ecr"
  mock_outputs                            = { repository_url = "000000000000.dkr.ecr.us-east-1.amazonaws.com/watch" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "connection" {
  config_path                             = "../connection"
  mock_outputs                            = { connection_arn = "arn:aws:codestar-connections:us-east-1:000000000000:connection/mock" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "staging_app" {
  config_path = "../staging/app"
  mock_outputs = {
    cluster_name            = "watch-staging", service_name = "watch-staging"
    production_listener_arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/app/watch-staging/x/y"
    test_listener_arn       = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/app/watch-staging/x/z"
    blue_target_group_name  = "watch-staging-blue", green_target_group_name = "watch-staging-green"
    execution_role_arn      = "arn:aws:iam::000000000000:role/watch-staging-exec"
    task_role_arn           = "arn:aws:iam::000000000000:role/watch-staging-task"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "prod_app" {
  config_path = "../prod/app"
  mock_outputs = {
    cluster_name            = "watch-prod", service_name = "watch-prod"
    production_listener_arn = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/app/watch-prod/x/y"
    https_listener_arn      = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/app/watch-prod/x/h"
    test_listener_arn       = "arn:aws:elasticloadbalancing:us-east-1:000000000000:listener/app/watch-prod/x/z"
    blue_target_group_name  = "watch-prod-blue", green_target_group_name = "watch-prod-green"
    execution_role_arn      = "arn:aws:iam::000000000000:role/watch-prod-exec"
    task_role_arn           = "arn:aws:iam::000000000000:role/watch-prod-task"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "staging_network" {
  config_path                             = "../staging/network"
  mock_outputs                            = { private_subnet_ids = ["subnet-sa", "subnet-sb"], app_sg_id = "sg-staging-app" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "prod_network" {
  config_path                             = "../prod/network"
  mock_outputs                            = { private_subnet_ids = ["subnet-pa", "subnet-pb"], app_sg_id = "sg-prod-app" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

terraform {
  source = "${get_repo_root()}//modules/pipeline"
}

inputs = {
  name               = "watch"
  region             = local.region
  github_repo_id     = "gotoplanb/watch"
  github_branch      = "main"
  connection_arn     = dependency.connection.outputs.connection_arn
  ecr_repository_url = dependency.ecr.outputs.repository_url

  # Cross-account prod deploy (ADR-020): the DeployProd action assumes this predictable role in
  # watch-prod (created by prod/deploy). Empty when prod is NOT a separate account -> the pipeline
  # deploys in-account and has nothing to assume.
  prod_deploy_role_arn = local.acct.has_prod ? "arn:aws:iam::${local.acct.prod_account_id}:role/watch-prod-deploy" : ""

  staging = {
    cluster_name            = dependency.staging_app.outputs.cluster_name
    service_name            = dependency.staging_app.outputs.service_name
    task_family             = "watch-staging"
    production_listener_arn = dependency.staging_app.outputs.production_listener_arn
    test_listener_arn       = dependency.staging_app.outputs.test_listener_arn
    blue_target_group_name  = dependency.staging_app.outputs.blue_target_group_name
    green_target_group_name = dependency.staging_app.outputs.green_target_group_name
    execution_role_arn      = dependency.staging_app.outputs.execution_role_arn
    task_role_arn           = dependency.staging_app.outputs.task_role_arn
    private_subnet_ids      = dependency.staging_network.outputs.private_subnet_ids
    app_sg_id               = dependency.staging_network.outputs.app_sg_id
    rollback_alarm_names    = ["watch-staging-escalation-failed", "watch-staging-alb-5xx", "watch-staging-target-5xx"]
  }

  prod = {
    cluster_name            = dependency.prod_app.outputs.cluster_name
    service_name            = dependency.prod_app.outputs.service_name
    task_family             = "watch-prod"
    production_listener_arn = dependency.prod_app.outputs.https_listener_arn # :443 (#13)
    test_listener_arn       = dependency.prod_app.outputs.test_listener_arn
    blue_target_group_name  = dependency.prod_app.outputs.blue_target_group_name
    green_target_group_name = dependency.prod_app.outputs.green_target_group_name
    execution_role_arn      = dependency.prod_app.outputs.execution_role_arn
    task_role_arn           = dependency.prod_app.outputs.task_role_arn
    private_subnet_ids      = dependency.prod_network.outputs.private_subnet_ids
    app_sg_id               = dependency.prod_network.outputs.app_sg_id
    rollback_alarm_names    = ["watch-prod-escalation-failed", "watch-prod-alb-5xx", "watch-prod-target-5xx"]
  }
}

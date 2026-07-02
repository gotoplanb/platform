# App stack for watch / prod / us-east-1 (platform#6). ECS Fargate + ALB + ECR, composing
# the network (#3), data (#4), and config (#5) stacks. ha profile: tasks in private subnets.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "ecr" {
  config_path                             = "../../ecr"
  mock_outputs                            = { repository_url = "000000000000.dkr.ecr.us-east-1.amazonaws.com/watch" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Cert ARN from the split cert stack (#35) — no by-hostname lookup, no bootstrap cycle.
dependency "cert" {
  config_path                             = "../cert"
  mock_outputs                            = { certificate_arn = "arn:aws:acm:us-east-1:000000000000:certificate/mock" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id             = "vpc-mock"
    public_subnet_ids  = ["subnet-ma", "subnet-mb"]
    private_subnet_ids = ["subnet-pa", "subnet-pb"]
    alb_sg_id          = "sg-alb"
    app_sg_id          = "sg-app"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Telemetry gateway (#19): the app sidecar forwards OTLP here; the gateway exports to Grafana
# Cloud (ADR-016 §2). Applied before the app.
dependency "gateway" {
  config_path                             = "../gateway"
  mock_outputs                            = { endpoint = "gateway.watch-prod.svc:4317" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "data" {
  config_path = "../data"
  mock_outputs = {
    db_address        = "mock.rds.amazonaws.com"
    db_port           = 5432
    db_name           = "watch"
    db_username       = "watch"
    master_secret_arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:mock"
    valkey_url        = "redis://mock:6379/0"
    kms_key_arn       = "arn:aws:kms:us-east-1:000000000000:key/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "config" {
  config_path = "../config"
  mock_outputs = {
    django_secret_key_param_arn     = "arn:aws:ssm:us-east-1:000000000000:parameter/mock-django"
    intake_webhook_secret_param_arn = "arn:aws:ssm:us-east-1:000000000000:parameter/mock-webhook"
    appconfig_application_name      = "watch-prod"
    appconfig_environment_name      = "prod"
    appconfig_profile_name          = "flags"
    appconfig_read_policy_arn       = "arn:aws:iam::000000000000:policy/mock-appconfig"
    secrets_read_policy_arn         = "arn:aws:iam::000000000000:policy/mock-secrets"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

terraform {
  source = "${get_repo_root()}//modules/app"
}

inputs = {
  name   = "${local.env.project}-${local.env.env}"
  env    = local.env.env
  region = local.env.region

  private_networking   = local.env.private_networking
  image_repository_url = dependency.ecr.outputs.repository_url
  app_hostname         = "watch.davestanton.com" # adds the ALB :443 HTTPS listener (#13)
  certificate_arn      = dependency.cert.outputs.certificate_arn # from ../cert (#35)

  vpc_id             = dependency.network.outputs.vpc_id
  public_subnet_ids  = dependency.network.outputs.public_subnet_ids
  private_subnet_ids = dependency.network.outputs.private_subnet_ids
  alb_sg_id          = dependency.network.outputs.alb_sg_id
  app_sg_id          = dependency.network.outputs.app_sg_id

  db_address           = dependency.data.outputs.db_address
  db_port              = dependency.data.outputs.db_port
  db_name              = dependency.data.outputs.db_name
  db_username          = dependency.data.outputs.db_username
  db_master_secret_arn = dependency.data.outputs.master_secret_arn
  db_kms_key_arn       = dependency.data.outputs.kms_key_arn
  valkey_url           = dependency.data.outputs.valkey_url

  django_secret_key_param_arn     = dependency.config.outputs.django_secret_key_param_arn
  intake_webhook_secret_param_arn = dependency.config.outputs.intake_webhook_secret_param_arn
  appconfig_application_name      = dependency.config.outputs.appconfig_application_name
  appconfig_environment_name      = dependency.config.outputs.appconfig_environment_name
  appconfig_profile_name          = dependency.config.outputs.appconfig_profile_name
  appconfig_read_policy_arn       = dependency.config.outputs.appconfig_read_policy_arn
  secrets_read_policy_arn         = dependency.config.outputs.secrets_read_policy_arn

  telemetry_gateway_endpoint = dependency.gateway.outputs.endpoint

  # Going live: the pipeline (#10) builds the first image; CodeDeploy places green tasks
  # at this count. 1 task is enough to verify end-to-end (autoscaling floor = 1).
  desired_count = 1
  autoscale_min = 1
  autoscale_max = 4
}

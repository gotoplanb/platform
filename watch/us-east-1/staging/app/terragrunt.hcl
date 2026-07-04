# App stack for watch / staging / us-east-1 (platform#6). lean profile: tasks in public
# subnets with a public IP (no NAT). Ephemeral — created for a pipeline run then destroyed.

include "root" {
  path = find_in_parent_folders("terragrunt.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "ecr" {
  config_path                             = "../../ecr"
  mock_outputs                            = { repository_url = "000000000000.dkr.ecr.us-east-1.amazonaws.com/watch" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

# HTTPS on watch-stg (#34): take the ACM cert ARN from the cert stack (applied first), so no
# by-hostname lookup / bootstrap cycle. This also orders cert-before-app in the DAG.
dependency "cert" {
  config_path                             = "../cert"
  mock_outputs                            = { certificate_arn = "arn:aws:acm:us-east-1:000000000000:certificate/mock" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
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
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

# Telemetry gateway (#19): the app sidecar forwards OTLP here. Applied before the app.
dependency "gateway" {
  config_path                             = "../gateway"
  mock_outputs                            = { endpoint = "gateway.watch-staging.svc:4317" }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
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
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "config" {
  config_path = "../config"
  mock_outputs = {
    django_secret_key_param_arn     = "arn:aws:ssm:us-east-1:000000000000:parameter/mock-django"
    intake_webhook_secret_param_arn = "arn:aws:ssm:us-east-1:000000000000:parameter/mock-webhook"
    appconfig_application_name      = "watch-staging"
    appconfig_environment_name      = "staging"
    appconfig_profile_name          = "flags"
    appconfig_read_policy_arn       = "arn:aws:iam::000000000000:policy/mock-appconfig"
    secrets_read_policy_arn         = "arn:aws:iam::000000000000:policy/mock-secrets"
    session_user_hmac_key_param_arn = "arn:aws:ssm:us-east-1:000000000000:parameter/mock-hmac"
    checks_webhook_secret_param_arn = "arn:aws:ssm:us-east-1:000000000000:parameter/mock-checks"
    webhook_echo_secret_param_arn   = "arn:aws:ssm:us-east-1:000000000000:parameter/mock-echo"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
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
  app_hostname         = "watch-stg.davestanton.com"          # HTTPS :443 + CSRF/secure cookies (#34)
  certificate_arn      = dependency.cert.outputs.certificate_arn

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

  desired_count = 1
  autoscale_min = 1
  autoscale_max = 4

  # --- Async worker + cloud mode (ADR-025) ---
  # Pin the app image to the manually-built digest (CodeBuild promote is on hold): this also
  # feeds the worker task-def. The app SERVICE ignores task_definition (CodeDeploy owns it), so
  # the running app is shifted via a manual CodeDeploy of this same revision.
  image_uri = "${dependency.ecr.outputs.repository_url}:6d6f335"

  enable_worker        = true
  worker_desired_count = 1
  checks_local_mode    = false # enqueue Session Checks to SQS for the worker
  webhooks_local_mode  = false # enqueue webhook deliveries to SQS for the worker
  trace_store_provider = "none" # prove the drain first; Tempo wiring is a follow-up

  session_user_hmac_key_param_arn = dependency.config.outputs.session_user_hmac_key_param_arn
  checks_webhook_secret_param_arn = dependency.config.outputs.checks_webhook_secret_param_arn
  webhook_echo_secret_param_arn   = dependency.config.outputs.webhook_echo_secret_param_arn
}

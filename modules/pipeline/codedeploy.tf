# Staging CodeDeploy (ECS blue/green) — same account as the pipeline. Prod's CodeDeploy moved to
# watch-prod (modules/prod-deploy) because a deployment group must live in the account owning its
# ALB target groups/listeners (ADR-020). This module now wires only staging, via modules/codedeploy.

module "staging" {
  source                  = "../codedeploy"
  name                    = "${var.name}-staging"
  deploy_config_name      = var.deploy_config_name
  cluster_name            = var.staging.cluster_name
  service_name            = var.staging.service_name
  production_listener_arn = var.staging.production_listener_arn
  test_listener_arn       = var.staging.test_listener_arn
  blue_target_group_name  = var.staging.blue_target_group_name
  green_target_group_name = var.staging.green_target_group_name
  rollback_alarm_names    = var.staging.rollback_alarm_names
  tags                    = var.tags
}

# App secrets — referenced by ARN in the ECS task-def `secrets` block (#6).
output "django_secret_key_param_arn" {
  description = "SSM ARN for DJANGO_SECRET_KEY."
  value       = aws_ssm_parameter.django_secret_key.arn
}

output "intake_webhook_secret_param_arn" {
  description = "SSM ARN for INTAKE_WEBHOOK_SECRET."
  value       = aws_ssm_parameter.intake_webhook_secret.arn
}

output "django_secret_key_param_name" {
  value = aws_ssm_parameter.django_secret_key.name
}

output "intake_webhook_secret_param_name" {
  value = aws_ssm_parameter.intake_webhook_secret.name
}

# AppConfig coordinates — the app sets APPCONFIG_APPLICATION/ENVIRONMENT/PROFILE from these.
output "appconfig_application_name" {
  description = "APPCONFIG_APPLICATION for the app."
  value       = aws_appconfig_application.this.name
}

output "appconfig_application_id" {
  value = aws_appconfig_application.this.id
}

output "appconfig_environment_name" {
  description = "APPCONFIG_ENVIRONMENT for the app."
  value       = aws_appconfig_environment.this.name
}

output "appconfig_profile_name" {
  description = "APPCONFIG_PROFILE for the app."
  value       = aws_appconfig_configuration_profile.flags.name
}

# IAM policies for the app stack (#6) to attach to the task/execution roles.
output "appconfig_read_policy_arn" {
  description = "Attach to the ECS task role (AppConfig Agent)."
  value       = aws_iam_policy.appconfig_read.arn
}

output "secrets_read_policy_arn" {
  description = "Attach to the ECS execution role (SSM secrets)."
  value       = aws_iam_policy.secrets_read.arn
}

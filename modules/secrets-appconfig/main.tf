# Secrets + AppConfig flags (platform#5). Two halves behind one stack:
#   - SSM SecureString params (Django secret key, intake webhook secret) — generated here,
#     read by the ECS task at launch via the task-def `secrets` block (never inlined, §4.3).
#     The DB master credential lives in Secrets Manager (data stack #4); this adds the app
#     secrets. Both are referenced by ARN.
#   - AWS AppConfig application/environment/profile + a hosted flag document mirroring
#     local/flags (ADR-003), served to the app by the AppConfig Agent sidecar over the
#     same localhost:2772 path used locally.
# Self-contained per environment (application named watch-<env>) so the agent resolves it
# unambiguously. IAM is emitted as managed policies for the app stack (#6) to attach.

data "aws_caller_identity" "current" {}

data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

# ---- App secrets (SSM SecureString) -----------------------------------------

resource "random_password" "django_secret_key" {
  length  = 50
  special = true
}

resource "random_password" "intake_webhook_secret" {
  length  = 40
  special = false # shared secret compared verbatim; keep it URL/header-safe
}

resource "aws_ssm_parameter" "django_secret_key" {
  name        = "/watch/${var.env}/django-secret-key"
  description = "Django SECRET_KEY for ${var.name}."
  type        = "SecureString"
  value       = random_password.django_secret_key.result
  tags        = merge(var.tags, { Name = "${var.name}-django-secret-key" })
}

resource "aws_ssm_parameter" "intake_webhook_secret" {
  name        = "/watch/${var.env}/intake-webhook-secret"
  description = "Shared secret for machine-to-machine webhook intake (ADR-008) for ${var.name}."
  type        = "SecureString"
  value       = random_password.intake_webhook_secret.result
  tags        = merge(var.tags, { Name = "${var.name}-intake-webhook-secret" })
}

# ---- AppConfig --------------------------------------------------------------

resource "aws_appconfig_application" "this" {
  name        = var.name # watch-<env>: unambiguous per environment
  description = "Watch feature flags / rollout modes (${var.env})."
  tags        = merge(var.tags, { Name = var.name })
}

resource "aws_appconfig_environment" "this" {
  name           = var.env
  description    = "Watch ${var.env}."
  application_id = aws_appconfig_application.this.id
  tags           = merge(var.tags, { Name = "${var.name}-${var.env}" })
}

resource "aws_appconfig_configuration_profile" "flags" {
  name           = "flags"
  description    = "Flag/rollout-mode document (mirrors local/flags)."
  application_id = aws_appconfig_application.this.id
  location_uri   = "hosted"
  type           = "AWS.Freeform"
  tags           = merge(var.tags, { Name = "${var.name}-flags" })
}

resource "aws_appconfig_hosted_configuration_version" "flags" {
  application_id           = aws_appconfig_application.this.id
  configuration_profile_id = aws_appconfig_configuration_profile.flags.configuration_profile_id
  description              = "Flags for ${var.env}."
  content_type             = "application/json"
  content                  = jsonencode(var.flags)
}

# Deploy the current flag version to the environment. A flag change creates a new hosted
# version (above), which forces a new deployment here (deployments are immutable).
resource "aws_appconfig_deployment" "flags" {
  application_id           = aws_appconfig_application.this.id
  environment_id           = aws_appconfig_environment.this.environment_id
  configuration_profile_id = aws_appconfig_configuration_profile.flags.configuration_profile_id
  configuration_version    = tostring(aws_appconfig_hosted_configuration_version.flags.version_number)
  deployment_strategy_id   = "AppConfig.AllAtOnce" # immediate; flags are low-risk and ~45s-polled
  description              = "Deploy flags v${aws_appconfig_hosted_configuration_version.flags.version_number} to ${var.env}."
  tags                     = merge(var.tags, { Name = "${var.name}-flags-deploy" })
}

# ---- IAM (attached by the app stack #6) -------------------------------------

# AppConfig Agent (task role): read the flag configuration for this app only.
resource "aws_iam_policy" "appconfig_read" {
  name        = "${var.name}-appconfig-read"
  description = "AppConfig Agent: read ${var.name} flag configuration."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "appconfig:StartConfigurationSession",
        "appconfig:GetLatestConfiguration",
      ]
      Resource = "arn:aws:appconfig:${var.region}:${data.aws_caller_identity.current.account_id}:application/${aws_appconfig_application.this.id}/environment/${aws_appconfig_environment.this.environment_id}/configuration/${aws_appconfig_configuration_profile.flags.configuration_profile_id}"
    }]
  })
  tags = var.tags
}

# ECS execution role: pull the SSM SecureStrings (and decrypt) to inject as container env.
resource "aws_iam_policy" "secrets_read" {
  name        = "${var.name}-secrets-read"
  description = "ECS execution role: read ${var.name} app secrets from SSM."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = [aws_ssm_parameter.django_secret_key.arn, aws_ssm_parameter.intake_webhook_secret.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = data.aws_kms_alias.ssm.target_key_arn
      },
    ]
  })
  tags = var.tags
}

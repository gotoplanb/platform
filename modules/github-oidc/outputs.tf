output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider this module's roles trust. Passed in, not created here (platform#57)."
  value       = var.oidc_provider_arn
}

output "plan_role_arn" {
  description = "Role for terragrunt plan (read-only, any ref)."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Role for terragrunt apply (write, apply branch only)."
  value       = aws_iam_role.apply.arn
}

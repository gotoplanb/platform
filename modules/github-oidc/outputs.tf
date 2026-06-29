output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "plan_role_arn" {
  description = "Role for terragrunt plan (read-only, any ref)."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Role for terragrunt apply (write, apply branch only)."
  value       = aws_iam_role.apply.arn
}

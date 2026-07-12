output "role_arn" {
  description = "The hub-assumable role ARN — what the root terragrunt's assume_role targets."
  value       = aws_iam_role.access.arn
}

output "role_name" {
  description = "Set WATCH_MEMBER_ROLE_NAME to this if it isn't the OrganizationAccountAccessRole default."
  value       = aws_iam_role.access.name
}

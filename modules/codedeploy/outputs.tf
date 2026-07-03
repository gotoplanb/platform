output "app_name" {
  value = aws_codedeploy_app.this.name
}
output "deployment_group_name" {
  value = aws_codedeploy_deployment_group.this.deployment_group_name
}
output "service_role_arn" {
  value = aws_iam_role.this.arn
}

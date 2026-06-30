output "ecr_repository_url" {
  description = "Shared ECR repo the task def pulls from (passed in; platform#20)."
  value       = var.image_repository_url
}

output "alb_dns_name" {
  description = "ALB DNS (the #13 DNS record points at this)."
  value       = aws_lb.this.dns_name
}

output "alb_arn" {
  value = aws_lb.this.arn
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.app.arn
}

# Blue/green wiring for the CodeDeploy deployment group (#10).
output "blue_target_group_name" {
  value = aws_lb_target_group.blue.name
}

output "green_target_group_name" {
  value = aws_lb_target_group.green.name
}

output "production_listener_arn" {
  description = "Active production listener: :443 when app_hostname set (#13), else :80."
  value       = var.app_hostname != "" ? aws_lb_listener.https[0].arn : aws_lb_listener.production[0].arn
}

output "test_listener_arn" {
  value = aws_lb_listener.test.arn
}

output "task_role_arn" {
  description = "Task role — #7/#8 attach Step Functions / SQS policies here."
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "https_listener_arn" {
  description = "ALB :443 production listener (#13); null until app_hostname is set."
  value       = var.app_hostname != "" ? aws_lb_listener.https[0].arn : null
}

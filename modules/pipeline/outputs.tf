output "connection_arn" {
  description = "CodeConnections ARN in use (owned by the persistent connection stack, #33)."
  value       = var.connection_arn
}

output "pipeline_name" {
  value = aws_codepipeline.this.name
}

output "artifact_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "deploy_hook_functions" {
  description = "Per-env BeforeAllowTraffic hook function names."
  value       = { for k, fn in aws_lambda_function.hook : k => fn.function_name }
}

output "connection_arn" {
  description = "CodeConnections ARN — complete the OAuth handshake before the first run."
  value       = aws_codestarconnections_connection.github.arn
}

output "connection_status" {
  value = aws_codestarconnections_connection.github.connection_status
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

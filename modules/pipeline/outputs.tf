output "connection_arn" {
  description = "CodeConnections ARN — complete the OAuth handshake before the first run."
  value       = aws_codestarconnections_connection.github.arn
}

output "connection_status" {
  description = "PENDING until the one-time handshake is authorized."
  value       = aws_codestarconnections_connection.github.connection_status
}

output "pipeline_name" {
  value = aws_codepipeline.this.name
}

output "codebuild_project" {
  value = aws_codebuild_project.this.name
}

output "codedeploy_app" {
  value = aws_codedeploy_app.this.name
}

output "artifact_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "deploy_hook_function" {
  value = aws_lambda_function.hook.function_name
}

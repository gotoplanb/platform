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

output "artifact_bucket_arn" {
  value = aws_s3_bucket.artifacts.arn
}

# Consumed cross-account by the watch-prod deploy role (ADR-020) — the KMS key ARN isn't
# predictable, so prod/deploy takes it as a dependency output.
output "artifact_kms_key_arn" {
  value = aws_kms_key.artifacts.arn
}

output "deploy_hook_functions" {
  description = "Per-env BeforeAllowTraffic hook function names."
  value       = { for k, fn in aws_lambda_function.hook : k => fn.function_name }
}

output "state_bucket" {
  description = "S3 bucket holding Terraform/OpenTofu state."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "DynamoDB table used for state locking."
  value       = aws_dynamodb_table.locks.name
}

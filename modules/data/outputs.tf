output "db_address" {
  description = "RDS endpoint host (app POSTGRES_HOST)."
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "RDS port (app POSTGRES_PORT)."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Database name (app POSTGRES_DB)."
  value       = aws_db_instance.this.db_name
}

output "db_username" {
  description = "Master username (app POSTGRES_USER)."
  value       = aws_db_instance.this.username
}

output "master_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credential (JSON {username,password}). App reads :password:: in the task-def secrets block."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "valkey_primary_endpoint" {
  description = "Valkey primary endpoint host."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "valkey_port" {
  description = "Valkey port."
  value       = aws_elasticache_replication_group.this.port
}

output "valkey_url" {
  description = "App VALKEY_URL. rediss:// when transit encryption is on, else redis://."
  value       = "${var.valkey_transit_encryption ? "rediss" : "redis"}://${aws_elasticache_replication_group.this.primary_endpoint_address}:${aws_elasticache_replication_group.this.port}/0"
}

output "kms_key_arn" {
  description = "CMK protecting data at rest."
  value       = aws_kms_key.data.arn
}

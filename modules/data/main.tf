# Data stack (platform#4). RDS Postgres + ElastiCache Valkey in the private tier, both
# behind the network stack's data SG (app->data only). Master credential is managed by
# RDS in Secrets Manager with automatic rotation (manage_master_user_password); the app
# stack (#6) references the secret ARN in the task-def `secrets` block — never inlined
# (ADR §4.3). KMS CMK encrypts storage, the master secret, and Performance Insights.
# multi_az toggles ADR-005 survival (lean single-AZ <-> ha Multi-AZ).

# ---- KMS --------------------------------------------------------------------

resource "aws_kms_key" "data" {
  description             = "${var.name} data-at-rest (RDS, master secret, PI)."
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = var.name })
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name}-data"
  target_key_id = aws_kms_key.data.key_id
}

# ---- RDS Postgres -----------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.private_subnet_ids
  tags       = merge(var.tags, { Name = "${var.name}-db" })
}

# Enforce TLS at the DB. The app connects with sslmode=require (RDS serves a cert by
# default); rds.force_ssl rejects any plaintext connection.
resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-pg-"
  family      = var.postgres_family
  description = "${var.name} Postgres params (force SSL)."

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, { Name = "${var.name}-pg" })
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-pg"
  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.master_username
  # RDS creates + rotates the master credential in Secrets Manager, encrypted with our CMK.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.data.arn

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.data.arn

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.data_sg_id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  port                   = 5432

  backup_retention_period    = var.backup_retention_days
  auto_minor_version_upgrade = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  performance_insights_kms_key_id       = aws_kms_key.data.arn

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-pg-final"
  apply_immediately         = true

  tags = merge(var.tags, { Name = "${var.name}-pg" })
}

# ---- ElastiCache Valkey -----------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-valkey"
  subnet_ids = var.private_subnet_ids
  tags       = merge(var.tags, { Name = "${var.name}-valkey" })
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name}-valkey"
  description          = "${var.name} sessions/cache (Valkey)."

  engine         = "valkey"
  engine_version = var.valkey_version
  node_type      = var.valkey_node_type
  port           = 6379

  # ha: a replica + automatic failover across AZs. lean: single node.
  num_cache_clusters         = var.multi_az ? 2 : 1
  automatic_failover_enabled = var.multi_az
  multi_az_enabled           = var.multi_az

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [var.data_sg_id]

  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.data.arn
  transit_encryption_enabled = var.valkey_transit_encryption

  snapshot_retention_limit = var.multi_az ? 5 : 0
  apply_immediately        = true

  tags = merge(var.tags, { Name = "${var.name}-valkey" })
}

# =============================================================================
# MariaDB on RDS.
#
# The master password is generated and stored by AWS (`manage_master_user_password`)
# and rotated automatically - it never enters a variable or a .tfvars file. The
# Ansible deploy role reads it from Secrets Manager via the instance role.
#
# The parameter group reproduces config/mariadb/conf.d/solrise.cnf, which only
# applies to the containerised database.
# =============================================================================

resource "aws_db_parameter_group" "mariadb" {
  # Family is part of the name so a family bump can create-before-destroy.
  # RDS parameter group names allow alphanumerics and hyphens only.
  name        = "${local.name}-${replace(var.db_parameter_group_family, ".", "")}"
  family      = var.db_parameter_group_family
  description = "Solrise ERP MariaDB settings (utf8mb4, Frappe-friendly)"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }

  # RDS equivalent of the container's --skip-character-set-client-handshake:
  # force utf8mb4 for clients that do not set the charset themselves.
  parameter {
    name  = "character_set_client"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_connection"
    value = "utf8mb4"
  }

  parameter {
    name  = "character_set_results"
    value = "utf8mb4"
  }

  parameter {
    name  = "max_allowed_packet"
    value = "67108864" # 64 MB - the 16 MB default bites large imports
  }

  parameter {
    name  = "innodb_buffer_pool_size"
    value = "{DBInstanceClassMemory*3/4}"
  }

  parameter {
    name  = "innodb_flush_log_at_trx_commit"
    value = "2"
  }

  parameter {
    name  = "skip_name_resolve"
    value = "1"
  }

  tags = { Name = "${local.name}-mariadb-pg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  identifier     = "${local.name}-db"
  engine         = "mariadb"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  port     = var.db_port

  # AWS creates the secret in Secrets Manager and rotates it; the password is
  # never written to Terraform configuration.
  manage_master_user_password = true

  parameter_group_name   = aws_db_parameter_group.mariadb.name
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az                   = var.db_multi_az
  publicly_accessible        = false
  backup_retention_period    = var.db_backup_retention_days
  backup_window              = "18:00-19:00" # UTC
  maintenance_window         = "sun:19:00-sun:20:00"
  auto_minor_version_upgrade = true
  apply_immediately          = var.db_apply_immediately

  performance_insights_enabled = var.db_performance_insights

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.name}-db-final"

  tags = { Name = "${local.name}-db" }
}

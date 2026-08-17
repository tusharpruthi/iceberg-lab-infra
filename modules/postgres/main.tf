resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-postgres"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.project_name}-postgres"
  }
}

# rds.logical_replication turns on wal_level=logical (RDS's own mechanism — you can't set
# wal_level directly on a managed instance). shared_preload_libraries adds pg_cron so dummy data
# can be scheduled *inside* Postgres without any external scheduler. Both are static parameters:
# changing them marks the instance for a reboot, which Terraform triggers via apply_immediately
# on the DB instance below.
resource "aws_db_parameter_group" "this" {
  name   = "${var.project_name}-postgres16"
  family = "postgres16"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_cron"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.project_name}-postgres16"
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.project_name}-postgres"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage_gb
  storage_type      = "gp3"

  db_name  = var.db_name
  username = var.username
  # Playground simplification: a plain variable, not SSM/Secrets-Manager-managed. Set via
  # terraform.tfvars (gitignored), never committed. This is a deliberate trade against the
  # earlier SSM-based design — accepted here because this is disposable test data, not real
  # sensitive data. See PLAN.md for the fuller reasoning.
  password = var.master_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = false

  # Playground: no need for backup retention beyond the minimum, no deletion protection, no
  # mandatory final snapshot if this is ever torn down entirely.
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  # Parameter group changes apply on the next apply instead of waiting for a maintenance window —
  # this instance is meant to be started/stopped/reconfigured interactively, not left alone.
  apply_immediately = true

  tags = {
    Name = "${var.project_name}-postgres"
  }
}

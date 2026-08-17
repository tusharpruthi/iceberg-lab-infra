output "region" {
  value = var.region
}

output "aws_account_id" {
  description = "The AWS account Terraform actually authenticated against — check this before trusting any plan/apply."
  value       = data.aws_caller_identity.current.account_id
}

output "static_allowed_cidrs" {
  description = "Read by scripts/start.sh and stop.sh to merge with your freshly-fetched current IP when building the full allowed_cidrs list."
  value       = var.static_allowed_cidrs
}

output "postgres_endpoint" {
  value = module.postgres.endpoint
}

output "postgres_address" {
  value = module.postgres.address
}

output "postgres_port" {
  value = module.postgres.port
}

output "postgres_db_name" {
  value = module.postgres.db_name
}

output "postgres_username" {
  value = module.postgres.username
}

output "postgres_identifier" {
  description = "Used by scripts/start.sh and scripts/stop.sh for aws rds start-db-instance/stop-db-instance."
  value       = module.postgres.identifier
}

output "postgres_master_password" {
  description = "Read by scripts/submit-job.sh via `terraform output -raw`. Sensitive: hidden from plan/apply output."
  value       = module.postgres.master_password
  sensitive   = true
}

output "warehouse_bucket_name" {
  value = module.storage.bucket_name
}

output "warehouse_path" {
  description = "Value for the app's ICEBERG_WAREHOUSE env var."
  value       = module.storage.warehouse_path
}

output "glue_database_name" {
  value = module.storage.glue_database_name
}

output "emr_cluster_id" {
  value = module.emr.cluster_id
}

output "emr_master_public_dns" {
  value = module.emr.master_public_dns
}

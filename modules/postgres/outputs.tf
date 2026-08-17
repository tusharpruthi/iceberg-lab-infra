output "identifier" {
  description = "RDS instance identifier — used by scripts/start.sh and stop.sh for start-db-instance/stop-db-instance."
  value       = aws_db_instance.this.identifier
}

output "endpoint" {
  description = "host:port"
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "host only, no port"
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "username" {
  value = aws_db_instance.this.username
}

output "master_password" {
  description = "Plain RDS master password — read by scripts/submit-job.sh at run time. Sensitive: hidden from plan/apply output, still readable via `terraform output -raw`."
  value       = var.master_password
  sensitive   = true
}

variable "project_name" {
  type = string
}

variable "subnet_ids" {
  description = "At least 2 subnet IDs across different AZs, for the RDS DB subnet group."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "instance_class" {
  type = string
}

variable "allocated_storage_gb" {
  type = number
}

variable "engine_version" {
  type = string
}

variable "db_name" {
  type = string
}

variable "username" {
  type = string
}

variable "master_password" {
  description = "RDS master password. Set via terraform.tfvars (gitignored) — never given a default here."
  type        = string
  sensitive   = true
}

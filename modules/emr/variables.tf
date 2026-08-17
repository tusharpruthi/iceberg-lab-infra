variable "project_name" {
  type = string
}

variable "create" {
  description = "Whether the EMR cluster (and nothing else in this module) should exist."
  type        = bool
}

variable "region" {
  type = string
}

variable "release_label" {
  type = string
}

variable "master_instance_type" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "key_pair_name" {
  type = string
}

variable "warehouse_bucket_name" {
  type = string
}

variable "warehouse_bucket_arn" {
  type = string
}

variable "glue_database_name" {
  type = string
}

variable "idle_timeout_minutes" {
  description = <<-EOT
    Auto-terminate the cluster after this many minutes with no active EMR step, as a safety net
    against forgetting to run scripts/stop.sh — this is the expensive resource in the whole
    stack. Terraform-driven start/stop is still the primary mechanism; this only guards against
    it being left running by accident.
  EOT
  type        = number
  default     = 60
}

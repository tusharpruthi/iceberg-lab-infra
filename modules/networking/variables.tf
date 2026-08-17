variable "project_name" {
  type = string
}

variable "allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach SSH/Flink-UI/Trino-UI on the EMR master. A list, not a single value —
    typically your own current IP (kept fresh by scripts/start.sh/stop.sh) plus any static IPs
    that should always have access, e.g. a company VPN's NAT egress IP.
  EOT
  type        = list(string)
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "public_subnet_secondary_cidr" {
  description = "Second public subnet, different AZ — exists only so the RDS DB subnet group has 2 AZs to satisfy AWS's requirement."
  type        = string
  default     = "10.0.2.0/24"
}

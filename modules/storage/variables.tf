variable "project_name" {
  type = string
}

variable "glue_database_name" {
  description = <<-EOT
    Glue Catalog Database name. Must match the source schema name the app uses as its Iceberg
    namespace (SourceDatabaseConfig.schema, default "public") — pre-creating it here means the
    app's own namespace-creation path never needs to run, so IAM can skip glue:CreateDatabase
    entirely and stay scoped to this one database.
  EOT
  type        = string
  default     = "public"
}

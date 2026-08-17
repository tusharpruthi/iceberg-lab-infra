output "bucket_name" {
  value = aws_s3_bucket.warehouse.id
}

output "bucket_arn" {
  value = aws_s3_bucket.warehouse.arn
}

output "warehouse_path" {
  description = "S3 path the app's ICEBERG_WAREHOUSE env var should point at."
  value       = "s3://${aws_s3_bucket.warehouse.id}/warehouse"
}

output "glue_database_name" {
  value = aws_glue_catalog_database.iceberg.name
}

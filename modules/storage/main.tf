# S3 bucket names are globally unique across all AWS accounts — a random suffix avoids
# collisions without the user having to hand-pick a unique name.
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "warehouse" {
  bucket = "${var.project_name}-warehouse-${random_id.bucket_suffix.hex}"

  tags = {
    Name = "${var.project_name}-warehouse"
  }
}

resource "aws_s3_bucket_public_access_block" "warehouse" {
  bucket = aws_s3_bucket.warehouse.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Playground-scale data: versioning stays off to avoid accumulating noncurrent-version storage
# cost from repeated CDC writes. The one lifecycle rule just cleans up multipart upload debris
# from interrupted writes.
resource "aws_s3_bucket_lifecycle_configuration" "warehouse" {
  bucket = aws_s3_bucket.warehouse.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    # The provider requires an explicit filter (or prefix) on every rule now, even to mean
    # "apply to every object, no filtering" — omitting it is deprecated and warns that it'll
    # become a hard error in a future provider version.
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_glue_catalog_database" "iceberg" {
  name        = var.glue_database_name
  description = "Iceberg namespace for ${var.project_name} — matches the app's source schema name."
}

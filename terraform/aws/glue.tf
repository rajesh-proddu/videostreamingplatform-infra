# ─── Glue Data Catalog + Schema Registry + Iceberg S3 ────────────────────────
# Replaces LocalStack Glue used in Kind. The catalog holds the watch_history
# Iceberg table; the Schema Registry holds Avro schemas for Kafka events.

resource "aws_glue_catalog_database" "analytics" {
  name        = var.glue_database_name
  description = "Iceberg tables for the analytics pipeline"
}

resource "aws_glue_registry" "schemas" {
  registry_name = "videostreamingplatform-${var.environment}"
  description   = "Avro event schemas (video-events, watch-events)"
}

# ─── Iceberg warehouse (S3) ──────────────────────────────────────────────────

resource "aws_s3_bucket" "iceberg_warehouse" {
  bucket = "${var.iceberg_warehouse_bucket}-${var.environment}"
}

resource "aws_s3_bucket_versioning" "iceberg_warehouse" {
  bucket = aws_s3_bucket.iceberg_warehouse.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "iceberg_warehouse" {
  bucket = aws_s3_bucket.iceberg_warehouse.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "iceberg_warehouse" {
  bucket = aws_s3_bucket.iceberg_warehouse.id

  rule {
    id     = "tiered-storage"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 365
      storage_class = "GLACIER"
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "iceberg_warehouse" {
  bucket                  = aws_s3_bucket.iceberg_warehouse.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

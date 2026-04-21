# ─── Athena workgroup ────────────────────────────────────────────────────────
# Ad-hoc SQL over the Glue-catalogued Iceberg tables. Engine v3 is required
# for Iceberg support. Results go to a dedicated bucket so the warehouse
# bucket stays clean.

resource "aws_s3_bucket" "athena_results" {
  bucket        = "videostreamingplatform-athena-results-${var.environment}"
  force_destroy = var.environment == "dev"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expire-results"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

resource "aws_athena_workgroup" "analytics" {
  name  = "videostreamingplatform-${var.environment}"
  state = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    # Dev caps each query at 1 GB scanned to avoid runaway bills.
    bytes_scanned_cutoff_per_query = var.environment == "dev" ? 1073741824 : null

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }

  force_destroy = var.environment == "dev"
}

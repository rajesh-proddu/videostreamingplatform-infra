# ─── SSM Parameter Store ─────────────────────────────────────────────────────
# Every value that lives in a values-aws.yaml placeholder today gets written
# here. The external-secrets-operator reads from /videostreamingplatform/${env}/*
# and materializes them into in-cluster Secrets consumed by the workloads.

locals {
  ssm_prefix = "/videostreamingplatform/${var.environment}"
}

resource "aws_ssm_parameter" "msk_bootstrap_brokers" {
  name  = "${local.ssm_prefix}/msk/bootstrap_brokers"
  type  = "String"
  value = aws_msk_serverless_cluster.events.bootstrap_brokers_sasl_iam
}

resource "aws_ssm_parameter" "opensearch_endpoint" {
  name  = "${local.ssm_prefix}/opensearch/endpoint"
  type  = "String"
  value = "https://${aws_opensearch_domain.search.endpoint}"
}

resource "aws_ssm_parameter" "pgvector_endpoint" {
  name  = "${local.ssm_prefix}/pgvector/endpoint"
  type  = "String"
  value = aws_rds_cluster.pgvector.endpoint
}

resource "aws_ssm_parameter" "pgvector_database" {
  name  = "${local.ssm_prefix}/pgvector/database"
  type  = "String"
  value = aws_rds_cluster.pgvector.database_name
}

resource "aws_ssm_parameter" "pgvector_secret_arn" {
  name  = "${local.ssm_prefix}/pgvector/secret_arn"
  type  = "String"
  value = aws_secretsmanager_secret.pgvector.arn
}

resource "aws_ssm_parameter" "iceberg_warehouse" {
  name  = "${local.ssm_prefix}/iceberg/warehouse"
  type  = "String"
  value = "s3://${aws_s3_bucket.iceberg_warehouse.bucket}/"
}

resource "aws_ssm_parameter" "glue_schema_registry" {
  name  = "${local.ssm_prefix}/glue/schema_registry"
  type  = "String"
  value = aws_glue_registry.schemas.registry_name
}

resource "aws_ssm_parameter" "athena_workgroup" {
  name  = "${local.ssm_prefix}/athena/workgroup"
  type  = "String"
  value = aws_athena_workgroup.analytics.name
}

resource "aws_ssm_parameter" "athena_results_bucket" {
  name  = "${local.ssm_prefix}/athena/results_bucket"
  type  = "String"
  value = aws_s3_bucket.athena_results.bucket
}

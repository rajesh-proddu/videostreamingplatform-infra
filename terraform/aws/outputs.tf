output "msk_cluster_arn" {
  description = "MSK Serverless cluster ARN"
  value       = aws_msk_serverless_cluster.events.arn
}

output "msk_bootstrap_brokers_sasl_iam" {
  description = "Kafka bootstrap brokers (SASL/IAM)"
  value       = aws_msk_serverless_cluster.events.bootstrap_brokers_sasl_iam
}

output "pgvector_endpoint" {
  description = "Aurora Postgres writer endpoint"
  value       = aws_rds_cluster.pgvector.endpoint
}

output "pgvector_reader_endpoint" {
  description = "Aurora Postgres reader endpoint"
  value       = aws_rds_cluster.pgvector.reader_endpoint
}

output "pgvector_database_name" {
  description = "Database name"
  value       = aws_rds_cluster.pgvector.database_name
}

output "pgvector_master_secret_arn" {
  description = "Secrets Manager ARN with master credentials"
  value       = aws_secretsmanager_secret.pgvector.arn
}

output "glue_database_name" {
  description = "Glue catalog database name for Iceberg tables"
  value       = aws_glue_catalog_database.analytics.name
}

output "glue_schema_registry_arn" {
  description = "Glue Schema Registry ARN"
  value       = aws_glue_registry.schemas.arn
}

output "iceberg_warehouse_bucket" {
  description = "S3 bucket backing the Iceberg warehouse"
  value       = aws_s3_bucket.iceberg_warehouse.bucket
}

output "iceberg_warehouse_location" {
  description = "s3:// URI for the Iceberg warehouse root"
  value       = "s3://${aws_s3_bucket.iceberg_warehouse.bucket}/"
}

output "analytics_irsa_role_arn" {
  description = "IRSA role ARN for analytics-sa"
  value       = aws_iam_role.analytics.arn
}

output "recommendations_irsa_role_arn" {
  description = "IRSA role ARN for recommendations-sa"
  value       = aws_iam_role.recommendations.arn
}

output "bedrock_ranking_model_id" {
  description = "Bedrock model used for LLM ranking"
  value       = var.bedrock_ranking_model_id
}

output "bedrock_embedding_model_id" {
  description = "Bedrock model used for embeddings"
  value       = var.bedrock_embedding_model_id
}

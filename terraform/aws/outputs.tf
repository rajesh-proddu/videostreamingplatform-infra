output "glue_database_name" {
  description = "Glue catalog database name for Iceberg tables"
  value       = aws_glue_catalog_database.analytics.name
}

output "glue_schema_registry_arn" {
  description = "Glue Schema Registry ARN"
  value       = aws_glue_registry.schemas.arn
}

output "glue_schema_registry_name" {
  description = "Glue Schema Registry name"
  value       = aws_glue_registry.schemas.registry_name
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

output "athena_workgroup" {
  description = "Athena workgroup name"
  value       = aws_athena_workgroup.analytics.name
}

output "athena_results_bucket" {
  description = "S3 bucket for Athena query results"
  value       = aws_s3_bucket.athena_results.bucket
}

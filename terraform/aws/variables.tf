variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev | prod)"
  type        = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be dev or prod."
  }
}

variable "bedrock_ranking_model_id" {
  description = "Bedrock model ID used by recommendations for LLM ranking"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "bedrock_embedding_model_id" {
  description = "Bedrock model ID used for video embeddings"
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "iceberg_warehouse_bucket" {
  description = "S3 bucket for the Iceberg warehouse. Created by this module."
  type        = string
  default     = "videostreamingplatform-iceberg-warehouse"
}

variable "glue_database_name" {
  description = "Glue catalog database for Iceberg tables"
  type        = string
  default     = "analytics"
}

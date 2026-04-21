# ─── OpenSearch Service ──────────────────────────────────────────────────────
# Managed Elasticsearch replacement for the in-cluster `elasticsearch` Service.
# Analytics' kafka-es-consumer writes the video search index; recommendations
# reads it. VPC-attached with fine-grained IAM auth (no master user).

resource "aws_security_group" "opensearch" {
  name        = "videostreamingplatform-opensearch-${var.environment}"
  description = "OpenSearch Service SG — HTTPS from VPC"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_opensearch_domain" "search" {
  domain_name    = "videostreamingplatform-${var.environment}"
  engine_version = var.opensearch_engine_version

  cluster_config {
    instance_type          = var.opensearch_instance_type
    instance_count         = var.opensearch_instance_count
    zone_awareness_enabled = var.opensearch_instance_count > 1

    dynamic "zone_awareness_config" {
      for_each = var.opensearch_instance_count > 1 ? [1] : []
      content {
        availability_zone_count = min(var.opensearch_instance_count, 3)
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.opensearch_volume_size_gb
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  vpc_options {
    subnet_ids         = slice(local.private_subnet_ids, 0, min(var.opensearch_instance_count, length(local.private_subnet_ids)))
    security_group_ids = [aws_security_group.opensearch.id]
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = false
    anonymous_auth_enabled         = false
  }

  # Domain access policy — only the two IRSA roles can hit the HTTP API.
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = [
          aws_iam_role.analytics.arn,
          aws_iam_role.recommendations.arn,
        ]
      }
      Action   = "es:*"
      Resource = "arn:aws:es:${var.aws_region}:${local.account_id}:domain/videostreamingplatform-${var.environment}/*"
    }]
  })
}

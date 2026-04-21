# ─── IRSA roles ──────────────────────────────────────────────────────────────
# Two service-account-bound IAM roles, one per namespace:
#
#   analytics        → Glue catalog + Iceberg S3 + Athena
#   recommendations  → Bedrock invoke (LLM + embeddings)
#
# Kafka and Elasticsearch run in-cluster (KRaft StatefulSet + ES StatefulSet)
# so they need no IAM grants. pgvector is in-cluster too.
#
# The trust policy binds each role to a specific namespace + ServiceAccount
# via the EKS cluster's OIDC provider.

data "aws_iam_policy_document" "analytics_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:analytics:analytics-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "recommendations_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:recommendations:recommendations-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ─── Analytics role ──────────────────────────────────────────────────────────

resource "aws_iam_role" "analytics" {
  name               = "videostreamingplatform-analytics-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.analytics_trust.json
}

data "aws_iam_policy_document" "analytics_policy" {
  # Glue catalog + schema registry
  statement {
    sid    = "GlueCatalog"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:GetTable",
      "glue:GetTables",
      "glue:BatchCreatePartition",
      "glue:BatchDeletePartition",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:UpdatePartition",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${local.account_id}:catalog",
      aws_glue_catalog_database.analytics.arn,
      "arn:aws:glue:${var.aws_region}:${local.account_id}:table/${var.glue_database_name}/*",
    ]
  }
  statement {
    sid    = "GlueSchemaRegistry"
    effect = "Allow"
    actions = [
      "glue:GetSchema",
      "glue:GetSchemaByDefinition",
      "glue:GetSchemaVersion",
      "glue:CreateSchema",
      "glue:RegisterSchemaVersion",
    ]
    resources = [
      aws_glue_registry.schemas.arn,
      "arn:aws:glue:${var.aws_region}:${local.account_id}:schema/${aws_glue_registry.schemas.registry_name}/*",
    ]
  }
  # Iceberg warehouse S3
  statement {
    sid    = "IcebergWarehouseRW"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.iceberg_warehouse.arn,
      "${aws_s3_bucket.iceberg_warehouse.arn}/*",
    ]
  }
  # Athena — ad-hoc Iceberg queries on Glue-catalogued tables.
  statement {
    sid    = "AthenaQuery"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
    ]
    resources = [aws_athena_workgroup.analytics.arn]
  }
  statement {
    sid    = "AthenaResultsBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.athena_results.arn,
      "${aws_s3_bucket.athena_results.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "analytics" {
  name   = "videostreamingplatform-analytics-${var.environment}"
  policy = data.aws_iam_policy_document.analytics_policy.json
}

resource "aws_iam_role_policy_attachment" "analytics" {
  role       = aws_iam_role.analytics.name
  policy_arn = aws_iam_policy.analytics.arn
}

# ─── Recommendations role ────────────────────────────────────────────────────

resource "aws_iam_role" "recommendations" {
  name               = "videostreamingplatform-recommendations-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.recommendations_trust.json
}

data "aws_iam_policy_document" "recommendations_policy" {
  # Bedrock: invoke LLM ranker + embedding model
  statement {
    sid    = "BedrockInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_ranking_model_id}",
      "arn:aws:bedrock:${var.aws_region}::foundation-model/${var.bedrock_embedding_model_id}",
    ]
  }
}

resource "aws_iam_policy" "recommendations" {
  name   = "videostreamingplatform-recommendations-${var.environment}"
  policy = data.aws_iam_policy_document.recommendations_policy.json
}

resource "aws_iam_role_policy_attachment" "recommendations" {
  role       = aws_iam_role.recommendations.name
  policy_arn = aws_iam_policy.recommendations.arn
}

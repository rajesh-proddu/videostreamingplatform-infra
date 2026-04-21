# ─── MSK Serverless ──────────────────────────────────────────────────────────
# Pay-per-use Kafka. Replaces the KRaft StatefulSet used in Kind. Used by both
# analytics consumers and the recommendations service.

resource "aws_security_group" "msk" {
  name        = "videostreamingplatform-msk-${var.environment}"
  description = "MSK Serverless cluster SG"
  vpc_id      = local.vpc_id

  # Allow EKS nodes to reach MSK. The platform repo's EKS node SG tags itself
  # with Name pattern; we allow from anywhere in the VPC for simplicity since
  # MSK Serverless requires IAM auth (no anonymous access).
  ingress {
    description = "Kafka IAM-authenticated traffic from VPC"
    from_port   = 9098
    to_port     = 9098
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

resource "aws_msk_serverless_cluster" "events" {
  cluster_name = "videostreamingplatform-${var.environment}"

  vpc_config {
    subnet_ids         = local.private_subnet_ids
    security_group_ids = [aws_security_group.msk.id]
  }

  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }
}

# ─── Aurora Postgres Serverless v2 (with pgvector) ───────────────────────────
# Replaces the pgvector StatefulSet used in Kind. Serverless v2 scales from
# 0.5 ACU so it's cheap at idle but bursts under load. pgvector extension
# support requires Postgres >= 15.4.

resource "random_password" "pgvector_master" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "pgvector" {
  name = "videostreamingplatform/${var.environment}/pgvector/master"
}

resource "aws_secretsmanager_secret_version" "pgvector" {
  secret_id = aws_secretsmanager_secret.pgvector.id
  secret_string = jsonencode({
    username = var.pgvector_master_username
    password = random_password.pgvector_master.result
  })
}

resource "aws_db_subnet_group" "pgvector" {
  name       = "videostreamingplatform-pgvector-${var.environment}"
  subnet_ids = local.private_subnet_ids
}

resource "aws_security_group" "pgvector" {
  name        = "videostreamingplatform-pgvector-${var.environment}"
  description = "Aurora Postgres (pgvector) SG"
  vpc_id      = local.vpc_id

  ingress {
    description = "Postgres from VPC"
    from_port   = 5432
    to_port     = 5432
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

resource "aws_rds_cluster" "pgvector" {
  cluster_identifier     = "videostreamingplatform-pgvector-${var.environment}"
  engine                 = "aurora-postgresql"
  engine_mode            = "provisioned"
  engine_version         = "15.5"
  database_name          = var.pgvector_database_name
  master_username        = var.pgvector_master_username
  master_password        = random_password.pgvector_master.result
  db_subnet_group_name   = aws_db_subnet_group.pgvector.name
  vpc_security_group_ids = [aws_security_group.pgvector.id]

  skip_final_snapshot = var.environment == "dev"
  storage_encrypted   = true

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_capacity
    max_capacity = var.aurora_max_capacity
  }
}

resource "aws_rds_cluster_instance" "pgvector" {
  cluster_identifier = aws_rds_cluster.pgvector.id
  identifier         = "videostreamingplatform-pgvector-${var.environment}-1"
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.pgvector.engine
  engine_version     = aws_rds_cluster.pgvector.engine_version
}

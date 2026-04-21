terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  backend "s3" {
    bucket         = "videostreamingplatform-terraform-state"
    key            = "infra/aws/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "videostreamingplatform"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = "infra"
    }
  }
}

# Platform remote state — VPC, subnets, EKS OIDC provider come from the core repo.
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "videostreamingplatform-terraform-state"
    key    = "eks/terraform.tfstate"
    region = "us-east-1"
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id         = data.aws_caller_identity.current.account_id
  vpc_id             = data.terraform_remote_state.platform.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.platform.outputs.private_subnet_ids
  oidc_provider_arn  = data.terraform_remote_state.platform.outputs.eks_oidc_provider_arn
  # Strip "arn:aws:iam::<acct>:oidc-provider/" prefix to get the issuer host/path.
  oidc_issuer = replace(local.oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider//", "")
}

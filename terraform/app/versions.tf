terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial config. One state file per environment:
  #   terraform init -backend-config=envs/<env>.s3.tfbackend -backend-config="bucket=<state bucket>"
  backend "s3" {
    region       = "us-east-1" # must match the bootstrap bucket's region
    encrypt      = true
    use_lockfile = true # S3-native state locking (no DynamoDB table needed)
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Stack       = "app"
    }
  }
}

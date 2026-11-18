terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial config: the bucket name contains the account ID, so it is passed at
  # init time (see README). Backend blocks cannot reference variables.
  backend "s3" {
    key          = "shared/terraform.tfstate"
    region       = "us-east-1" # must match the bootstrap bucket's region
    encrypt      = true
    use_lockfile = true # S3-native state locking (no DynamoDB table needed)
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "shared"
    }
  }
}

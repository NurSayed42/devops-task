# Plan-only tests for the shared stack with a mocked AWS provider (no AWS
# account needed). Run from terraform/shared: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_ecr_repository.app.name == "devops-task-api" && aws_ecr_repository.app.image_tag_mutability == "IMMUTABLE"
    error_message = "The ECR repository must use immutable tags."
  }

  assert {
    condition     = aws_ecr_repository.app.image_scanning_configuration[0].scan_on_push
    error_message = "ECR must scan images on push."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.app.policy).rules[0].selection.tagStatus == "tagged"
    error_message = "The lifecycle policy must expire tagged releases only (never the untagged per-platform manifests)."
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1 && aws_iam_openid_connect_provider.github[0].url == "https://token.actions.githubusercontent.com"
    error_message = "The GitHub OIDC provider must be created by default."
  }

  assert {
    condition     = contains(flatten([for c in data.aws_iam_policy_document.ecr_push_trust.statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:sub"]), "repo:NurSayed42/devops-task:ref:refs/heads/main")
    error_message = "Only workflows on the main branch may assume the ECR push role."
  }

  assert {
    condition     = can(regex("use_lockfile *= *true", file("${path.module}/versions.tf")))
    error_message = "The S3 backend must enable use_lockfile (state locking)."
  }
}

run "reuses_an_existing_oidc_provider" {
  command = plan

  variables {
    create_github_oidc_provider = false
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "No OIDC provider may be created when one already exists."
  }
}

run "rejects_malformed_repository" {
  command = plan

  variables {
    github_repository = "not a repository"
  }

  expect_failures = [var.github_repository]
}

# Plan-only tests for the app stack with a mocked AWS provider: no AWS account,
# credentials or network needed. Run from terraform/app: terraform init -backend=false && terraform test
#
# Only attributes known at plan time are asserted (configuration values and
# mocked data sources), never computed values such as ARNs or IDs.

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = { id = "vpc-0mock" }
  }
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-0bbb", "subnet-0aaa"] }
  }
  mock_data "aws_ec2_instance_type_offerings" {
    defaults = { locations = ["us-east-1a", "us-east-1b"] }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-1:123456789012:repository/devops-task-api"
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/devops-task-api"
    }
  }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

run "staging" {
  command = plan

  # Values come from the real environment file, so the test also guards it.
  variables {
    environment        = "staging"
    log_retention_days = tonumber(regex("log_retention_days *= *([0-9]+)", file("envs/staging.tfvars"))[0])
  }

  # Network: default VPC, one security group in it
  assert {
    condition     = data.aws_vpc.default.default && aws_security_group.app.vpc_id == data.aws_vpc.default.id
    error_message = "The security group must be created in the default VPC."
  }

  assert {
    condition     = alltrue([for r in values(aws_vpc_security_group_ingress_rule.app) : r.ip_protocol == "tcp" && r.from_port == 80 && r.to_port == 80])
    error_message = "Ingress must be the app port (80/tcp) only."
  }

  assert {
    condition     = alltrue([for r in values(aws_vpc_security_group_ingress_rule.app) : !(r.from_port <= 22 && r.to_port >= 22)])
    error_message = "No ingress rule may open SSH (22), from 0.0.0.0/0 or anywhere else."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.https.from_port == 443 && aws_vpc_security_group_egress_rule.https.to_port == 443
    error_message = "Egress must be HTTPS (443) only."
  }

  # EC2: instance profile, IMDSv2, encrypted disk
  assert {
    condition     = aws_instance.app.iam_instance_profile == aws_iam_instance_profile.app.name
    error_message = "The instance must use the stack's IAM instance profile."
  }

  assert {
    condition     = aws_instance.app.metadata_options[0].http_tokens == "required" && aws_instance.app.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 must be required, with hop limit 1 (containers can't reach instance credentials)."
  }

  assert {
    condition     = aws_instance.app.root_block_device[0].encrypted
    error_message = "The root volume must be encrypted."
  }

  # Bootstrap: installs and starts Docker, ships a deploy script that runs the container
  assert {
    condition     = strcontains(aws_instance.app.user_data, "dnf install -y docker") && strcontains(aws_instance.app.user_data, "systemctl enable --now docker")
    error_message = "user_data must install and start Docker."
  }

  assert {
    condition     = strcontains(base64decode(regex("echo '([A-Za-z0-9+/=]+)' \\| base64 -d", aws_instance.app.user_data)[0]), "docker run")
    error_message = "user_data must install the deploy script that runs the app container."
  }

  # Logs: retention per environment
  assert {
    condition     = aws_cloudwatch_log_group.app.retention_in_days == 7
    error_message = "Staging log retention must be 7 days (envs/staging.tfvars)."
  }

  # Deploy role: only the GitHub Environment of the same name may assume it
  assert {
    condition     = contains(flatten([for c in data.aws_iam_policy_document.deploy_trust.statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:sub"]), "repo:NurSayed42/devops-task:environment:staging")
    error_message = "The staging deploy role must trust only the 'staging' GitHub Environment."
  }

  # Remote state: S3 backend with native locking
  assert {
    condition     = can(regex("use_lockfile *= *true", file("${path.module}/versions.tf")))
    error_message = "The S3 backend must enable use_lockfile (state locking)."
  }
}

run "production" {
  command = plan

  variables {
    environment        = "production"
    log_retention_days = tonumber(regex("log_retention_days *= *([0-9]+)", file("envs/production.tfvars"))[0])
  }

  assert {
    condition     = aws_cloudwatch_log_group.app.retention_in_days == 30
    error_message = "Production log retention must be 30 days (envs/production.tfvars)."
  }

  assert {
    condition     = aws_cloudwatch_log_group.app.name == "/devops-task/production/app" && aws_instance.app.tags["Name"] == "devops-task-production"
    error_message = "Resource names must carry the environment."
  }

  assert {
    condition     = contains(flatten([for c in data.aws_iam_policy_document.deploy_trust.statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:sub"]), "repo:NurSayed42/devops-task:environment:production")
    error_message = "The production deploy role must trust only the 'production' GitHub Environment."
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment        = "dev"
    log_retention_days = 7
  }

  expect_failures = [var.environment]
}

run "rejects_invalid_log_retention" {
  command = plan

  variables {
    environment        = "staging"
    log_retention_days = 10 # not a value CloudWatch Logs accepts
  }

  expect_failures = [var.log_retention_days]
}
